require "net/https"
require "uri"
require "redis"

# crawljob does the main retrival and handles creation of the processing
# job. Uses the class crawl to do most of the actual work.
class CrawlJob
  @queue = :cobweb_crawl_job

  VERBOSE = true

  def self.stats
    size = Resque.size(@queue)
    failed_count = Resque::Failure.all.select {|job| job['payload']['class'] == 'CrawlJob' }.count
    { queued: size, failed: failed_count }
  end

  # allows a console interface to do one iteration of the Resque queue
  def self.do_one
    popped_results = Resque.pop("#{@queue}")
    if popped_results
      args = popped_results['args'].first
      crawl_module = CrawlJob.perform(args)
      # passes out the crawl object so we can inspect it after it runs
      crawl_module
    else
      false
    end
  end

  # requeues up to 1000 jobs based on crawl id
  def self.requeue_failed_jobs(crawl_id)
    delete_indexes = []
    requeued_count = 0
    Resque::Failure::Redis.all(0,1000).each_with_index do |job, index|
      next if job['queue'] != @queue.to_s
      next if job['payload']['args'][0]['crawl_id'] != crawl_id
      requeued_count += 1
      Resque::Failure.requeue(index)
      delete_indexes << index
    end
    delete_indexes.each {|index| Resque::Failure.remove(index) }
    logger.info "CrawlJob REQUEUE #{requeued_count} at #{Time.now}"
    true
  end

  def self.failed_jobs_for_crawl(crawl_id)
    failed_jobs.select do |job|
      job['payload']['args'][0]['crawl_id'] == crawl_id
    end
  end

  def self.failed_jobs
    Resque::Failure::Redis.all(0,1000).select do |job|
      job['payload']['class'] == 'CrawlJob' rescue []
    end
  end

  # Resque perform method to maintain the crawl, enqueue
  # found links and detect the end of crawl
  def self.perform(content_request)
    # setup the crawl class to manage the crawl of this object
    @crawl = CobwebModule::Crawl.new(content_request)
    if @crawl.already_crawled?(content_request['url'])
      @crawl.redis.srem('currently_running', content_request['url'])
      logger.warn "CrawlJob WARN AlreadyCrawledURL #{content_request['url']}"
    else
      logger.info "CrawlJob PERFORMSTART URL #{content_request['url']}"
      # update the counters and then perform the get, returns
      # false if we are outwith limits
      if @crawl.retrieve
        # if the crawled object is an object type we are
        # moved out the procedssing to make this method shorter and
        # easier to read
        if @crawl.content.permitted_type?
          if @crawl.to_be_processed?
            @crawl, queued_links_count = queue_new_links_for_crawling(@crawl, content_request)
            @crawl, redirected_links_count = handle_redirects(@crawl, content_request)
            queued_links_count += redirected_links_count # add redirects
            begin
              @crawl = do_crawl_processing(@crawl, content_request)
              @crawl.store_graph_data
            rescue => e
              logger.error "Cobweb::CrawlJob ERROR #{e.inspect}"
              logger.error "#{e.backtrace.join("\n")}"
            end
            @crawl.print_counters
          else
            @crawl.logger.debug "@crawl.finished? #{@crawl.finished?}"
            @crawl.logger.debug "@crawl.within_crawl_limits? #{@crawl.within_crawl_limits?}"
            @crawl.logger.debug "@crawl.first_to_finish? #{@crawl.first_to_finish?}"
          end # if permitted content type
        else
          # @crawl.print_counters
          # not a valid content type for processing
          @crawl.logger.warn "CrawlJob: Invalid MimeType #{content_request.inspect}"
        end
      else
        @crawl.print_counters
        @crawl.logger.warn "CrawlJob: Retrieve FALSE #{content_request['url']}"
      end


      @crawl.lock("finished") do
        # mark the queues as done with this processing
        @crawl.finished_processing
        # test queue and crawl sizes to see if we have completed the crawl
        if @crawl.finished?
          @crawl.logger.debug "Calling crawl_job finished"
          finished(content_request)
        end
      end

      # ensure our existing URL has been removed from the
      # currently processing list
      @crawl.redis.srem('currently_running', content_request['url'])
      @crawl.logger.debug "CrawlJob Code:#{@crawl.content.status_code} URL:#{content_request[:url]}"
      current_failed_job_count = Array(CrawlJob.failed_jobs_for_crawl(content_request['crawl_id'])).count
      @crawl.logger.debug "Failed Jobs: #{current_failed_job_count}" if current_failed_job_count > 0
      @crawl.print_counters
    end
    @crawl
  end

  # Sets the crawl status to CobwebCrawlHelper::FINISHED and enqueues the crawl finished job
  def self.finished(content_request)
    additional_stats = {:crawl_id => content_request[:crawl_id], :crawled_base_url => @crawl.crawled_base_url}
    additional_stats[:redis_options] = content_request[:redis_options] unless content_request[:redis_options] == {}
    additional_stats[:source_id] = content_request[:source_id] unless content_request[:source_id].nil?

    @crawl.finish

    @crawl.logger.debug "increment crawl_finished_enqueued_count from #{@crawl.redis.get("crawl_finished_enqueued_count")}"
    @crawl.redis.incr("crawl_finished_enqueued_count")
    Resque.enqueue(const_get(content_request[:crawl_finished_queue]), @crawl.statistics.merge(additional_stats))
  end

  # Enqueues the content to the processing queue setup in options
  def self.send_to_processing_queue(content, content_request)
    content_to_send = content.merge({:depth => content_request[:depth], :internal_urls => content_request[:internal_urls], :redis_options => content_request[:redis_options], :source_id => content_request[:source_id], :crawl_id => content_request[:crawl_id], :data => content_request[:data]})
    if content_request[:direct_call_process_job]
      #clazz = content_request[:processing_queue].to_s.constantize
      clazz = const_get(content_request[:processing_queue])
      clazz.perform(content_to_send)
    elsif content_request[:use_encoding_safe_process_job]
      content_to_send[:body] = Base64.encode64(content[:body])
      content_to_send[:processing_queue] = content_request[:processing_queue]
      Resque.enqueue(EncodingSafeProcessJob, content_to_send)
    else
      Resque.enqueue(const_get(content_request[:processing_queue]), content_to_send)
    end
  end

  private

  # Enqueues content to the crawl_job queue
  def self.enqueue_content(crawl_object, content_request, link)
    unless crawl_object.already_handled?(link.to_s)
      content_request.symbolize_keys!
      new_request = content_request.dup
      new_request[:url] = link
      new_request[:parent] = content_request[:url]
      new_request[:depth] = content_request[:depth].to_i + 1
      Resque.enqueue(CrawlJob, new_request)
      crawl_object.redis.sadd('queued', new_request[:url].to_s)
      crawl_object.increment_queue_counter
    end
  end

  def self.queue_new_links_for_crawling(crawl_object, content_request)
    queued_links_count = 0
    crawl_object.process_links do |link|
      if crawl_object.within_crawl_limits?
        enqueue_content(crawl_object, content_request, link)
        queued_links_count += 1
      end
    end
    [crawl_object, queued_links_count]
  end

  def self.handle_redirects(crawl_object, content_request)
    redirected_links_count = 0
    Array(crawl_object.redirect_links).each do |link|
      enqueue_content(crawl_object, content_request, link)
      redirected_links_count += 1
    end
    [crawl_object, redirected_links_count]
  end

  def self.do_crawl_processing(crawl_object, content_request)
    crawl_object.process do
      # enqueue to processing queue
      send_to_processing_queue(crawl_object.content.to_hash, content_request)

      #if the enqueue counter has been requested update that
      if content_request.has_key?(:enqueue_counter_key)
        enqueue_redis = Redis::Namespace.new(content_request[:enqueue_counter_namespace].to_s, :redis => RedisConnection.new(content_request[:redis_options]))
        current_count = enqueue_redis.hget(content_request[:enqueue_counter_key], content_request[:enqueue_counter_field]).to_i
        enqueue_redis.hset(content_request[:enqueue_counter_key], content_request[:enqueue_counter_field], current_count+1)
      end

      if content_request[:store_response_codes]
        code_redis = Redis::Namespace.new("cobweb:#{content_request[:crawl_id]}", :redis => RedisConnection.new(content_request[:redis_options]))
        code_redis.hset("codes", Digest::MD5.hexdigest(content_request[:url]), crawl_object.content.status_code)
      end

      last_depth = crawl_object.redis.hget("depth", "#{Digest::MD5.hexdigest(content_request[:url])}").to_i
      if last_depth.nil? || (last_depth.to_i > content_request[:depth].try(:to_i))
        crawl_object.redis.hset("depth", "#{Digest::MD5.hexdigest(content_request[:url])}", content_request[:depth])
      end
    end
    crawl_object
  end

  # class-based logging
  def self.logger
    Logger.new(STDOUT)
  end

  def self.namespaced_redis(content_request)
    Redis::Namespace.new(
      "cobweb:#{content_request['crawl_id']}",
      redis: RedisConnection.new(content_request['redis_options'])
    )
  end

end

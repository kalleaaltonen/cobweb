# crawlstarter starts a crawl, based on passing it a set of options
class CrawlStarter
  attr_accessor :options

  # See readme for more information on options available
  def initialize(options = {})
    @options = options
    @options[:data] = {} if @options[:data].nil?
    default_use_encoding_safe_process_job_to  false
    default_follow_redirects_to               true
    default_redirect_limit_to                 10
    default_queue_system_to                   :resque
    if @options[:queue_system] == :resque
      default_processing_queue_to               "CobwebProcessJob"
      default_crawl_finished_queue_to           "CobwebFinishedJob"
    else
      default_processing_queue_to               "CrawlProcessWorker"
      default_crawl_finished_queue_to           "CrawlFinishedWorker"
    end
    default_quiet_to                          true
    default_debug_to                          false
    default_cache_to                          300
    default_cache_type_to                     :crawl_based # other option is :full
    default_timeout_to                        30
    default_redis_options_to                  Hash.new
    default_internal_urls_to                  []
    default_external_urls_to                  []
    default_seed_urls_to                  []
    default_first_page_redirect_internal_to   true
    default_text_mime_types_to                ["text/*", "application/xhtml+xml"]
    default_obey_robots_to                    false
    default_user_agent_to                     "bobobot/3.0.16 (ruby/#{RUBY_VERSION} nokogiri/#{Nokogiri::VERSION})"
    default_valid_mime_types_to                ["*/*"]
    default_raise_exceptions_to               false
    default_store_inbound_links_to            false
    default_proxy_addr_to                     nil
    default_proxy_port_to                     nil
    @content = Content.new
  end

  def logger
    @logger ||= Logger.new(STDOUT)
  end

  def crawl_id
    @crawl_id ||= begin
      if @options[:crawl_id]
        @options[:crawl_id]
      else
        Digest::SHA1.hexdigest("#{Time.now.to_i}.#{Time.now.usec}")
      end
    end
  end

  # This method starts the resque based crawl and enqueues the base_url
  def start(base_url)
    raise ":base_url is required" unless base_url
    request = {
      :crawl_id => crawl_id,
      :url => base_url
    }

    if @options[:internal_urls].nil? || @options[:internal_urls].empty?
      uri = Addressable::URI.parse(base_url)
      @options[:internal_urls] = []
      @options[:internal_urls] << [uri.scheme, "://", uri.host, "/*"].join
      @options[:internal_urls] << [uri.scheme, "://", uri.host, ":", uri.inferred_port, "/*"].join
    end

    request.merge!(@options)

    # set initial depth
    request[:depth] = 1

    @redis = Redis::Namespace.new("cobweb:#{request[:crawl_id]}", :redis => RedisConnection.new(request[:redis_options]))
    @redis.set("original_base_url", base_url)
    @redis.hset "statistics", "queued_at", DateTime.now
    @redis.set("crawl-counter", 0)
    @redis.set("queue-counter", 1)

    # adds the @options["data"] to the global space so it can be retrieved with a simple redis query
    if @options[:data]
      @options[:data].keys.each do |key|
        @redis.hset "data", key.to_s, @options[:data][key]
      end
    end

    # adds the options set to the statistics for subsequent processing
    @redis.hset "statistics", "options", @options.to_json

    # setup robots delay
    # this part is a bit weird, It requires resque-scheduler, but resque is
    # not a gem that is required by cobweb.  So, this is a bit weird and i question
    # whether this is the right way to do this
    if @options[:respect_robots_delay]
      @robots = robots_constructor(base_url, @options)
      if @robots.respond_to?(:delay)
        delay_set = @robots.delay || 0.5 # should be setup as an options with a default value
      else
        delay_set = 0.5
      end
      @redis.set("robots:per_page_delay", delay_set)
      @redis.set("robots:next_retrieval", Time.now)
    end

    # add the original URL to the request queue if it exists
    @redis.sadd "queued", request[:url] if request[:url]

    @stats = CobwebStats.new(request)
    @stats.start_crawl(request)

    # add internal_urls into redis
    @options[:internal_urls].map{ |url| @redis.sadd('internal_urls', url) }

    # queue the original one
    Resque.enqueue(CrawlJob, request)

    # queue the seed_urls as well into jobs
    duplicate_request = request.dup
    @options[:seed_urls].map do |link|
      duplicate_request[:url] = link
      Resque.enqueue(CrawlJob, duplicate_request)
      @redis.sadd "queued", link
    end

    # and return the original request
    request
  end

  # used for setting default options
  def method_missing(method_sym, *arguments, &block)
    if method_sym.to_s =~ /^default_(.*)_to$/
      tag_name = method_sym.to_s.split("_")[1..-2].join("_").to_sym
      @options[tag_name] = arguments[0] unless @options.has_key?(tag_name)
    else
      super
    end
  end

  # build data for constructor
  def robots_constructor(base_url, options)
    Robots.new(:url => base_url, :user_agent => options[:user_agent])
  end

end

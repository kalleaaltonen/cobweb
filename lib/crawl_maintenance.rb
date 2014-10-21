# crawl maintenance module cleans up problems with crawls, and otherwise
# allows the crawl to move itself forward
module CrawlMaintenance

  def self.stats
    size = Resque.size(@queue)
    failed_count = Resque::Failure.all.select {|job| job['payload']['class'] == 'CrawlJob' }.try(:count)
    { queued: size, failed: failed_count.to_i }
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

end

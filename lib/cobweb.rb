require 'rubygems'
require 'uri'
require "addressable/uri"
require 'digest/sha1'
require 'base64'
require 'typhoeus'

Dir[File.dirname(__FILE__) + '/**/*.rb'].each do |file|
  require file
end

# Cobweb class is used to perform get and head requests.
# You can use this on its own if you wish without the crawler
class Cobweb
  attr_reader :options

  # See readme for more information on options available
  def initialize(options = {})
    @options = options
    set_additional_options
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

  # Returns array of cookies from content
  def get_cookies(response)
    all_cookies = response.get_fields('set-cookie')
    unless all_cookies.nil?
      cookies_array = Array.new
      all_cookies.each { |cookie|
        cookies_array.push(cookie.split('; ')[0])
      }
      cookies = cookies_array.join('; ')
    end
  end

  def get(url, options = @options)
    perform(url, 'get', options)
  end

  def head(url, options = @options)
    perform(url, 'head', options)
  end

  # Performs a HTTP request of the requested method type
  def perform(url, method, options = @options)
    raise "url cannot be nil" if url.nil?

    # normalize the URL and generate a URI object
    url, uri = normalize_url(url)

    # sets the options for the retrieval
    set_options

    # create a unique id for this request
    unique_id = Digest::SHA1.hexdigest(url.to_s)

    # add the url to the return hash
    @content[:base_url] = url

    # retrieve data
    begin
      # request_options['Cookie']= options[:cookies] if options[:cookies]
      request_parameters[:method] = method
      set_request_time
      request = Typhoeus::Request.new(url, request_parameters)
      raw_response = request.run
      response = Response.new(raw_response, @options) # use our class parser for Typhoeus
      logger.info "Cobweb WARN NameLookup #{raw_response.namelookup_time}" if raw_response.namelookup_time > 1.0
      @content.merge!(response.to_hash)
      @content[:text_content] = text_content?(@content[:mime_type])

    rescue RedirectError => e
      raise e if @options[:raise_exceptions]
      logger.error "ERROR RedirectError: #{e.message}"
      set_content_to_error(uri.to_s, e.message, "error/redirecterror")

    rescue SocketError => e
      raise e if @options[:raise_exceptions]
      logger.error "ERROR SocketError: #{e.message}"
      set_content_to_error(uri.to_s, e.message, "error/socketerror")

    rescue Timeout::Error => e
      raise e if @options[:raise_exceptions]
      logger.error "ERROR Timeout::Error: #{e.message}"
      set_content_to_error(uri.to_s, e.message, "error/serverdown")
    end
    @content
  end

  # escapes characters with meaning in regular expressions and adds wildcard expression
  def self.escape_pattern_for_regex(pattern)
    pattern = pattern.gsub(".", "\\.")
    pattern = pattern.gsub("?", "\\?")
    pattern = pattern.gsub("+", "\\+")
    pattern = pattern.gsub("*", ".*?")
    pattern
  end

  def clear_cache;end

  def set_options
    set_proxy_options
    set_authentication_options
    set_user_agent
    set_follow_options
    set_logging_options
    set_timeout_options
    set_redirect_options
    true
  end

  # set proxy options if they are needed
  def set_proxy_options
    if @options[:proxy_addr] && @options[:proxy_port]
      request_parameters[:proxy] = "http://#{@options[:proxy_address]}:#{@options[:proxy_port]}"
      request_parameters[:proxytype] =Typhoeus::Easy::PROXY_TYPES[:CURLPROXY_HTTP]
      request_parameters[:proxyuserpwd] = "#{@options[:proxy_username]}:#{@options[:proxy_password]}"
    end
  end

  # set authentication options if they are needed
  def set_authentication_options
    if @options[:username] && @options[:password]
      request_parameters[:userpwd] = "#{@options[:username]}:#{@options[:password]}"
    end
  end

  # set the User Agent for the request
  def set_user_agent
    if @options[:user_agent]
      request_parameters[:headers] = {} if request_parameters[:headers].nil?
      request_parameters[:headers]["User-Agent"] = @options[:user_agent]
    end
  end

  # set followoptions for the request
  def set_follow_options
    if @options[:follow_redirects]
      request_parameters[:followlocation] = @options[:follow_redirects]
    end
  end

  # set followoptions for the request
  def set_logging_options
    if @options[:verbose]
      request_parameters[:verbose] = @options[:verbose]
    end
  end

  def set_timeout_options
    if @options[:timeout]
      request_parameters[:timeout] = @options[:timeout] * 1000
      request_parameters[:connecttimeout] = (@options[:timeout] / 2).to_i * 1000
    end
  end

  def set_redirect_options
    if @options.has_key?(:redirect_limit) and !@options[:redirect_limit].nil?
      request_parameters[:maxredirs] = @options[:redirect_limit]
    else
      request_parameters[:maxredirs] = 10
    end
  end

  # default hash, sets it to ignore ssl errors
  def request_parameters
    @request_parameters ||= {
      ssl_verifypeer: false
    }
  end

  # normalize the URL and return the URI and URL
  def normalize_url(url)
    uri = Addressable::URI.parse(url)
    uri.normalize!
    uri.fragment=nil
    url = uri.to_s
    [url, uri]
  end

  def reset_content_to_blank
    @content = Content.new
    @content[:url] = nil
    @content[:response_time] = 99999999.9
    @content[:status_code] = 0
    @content[:length] = 0
    @content[:body] = ""
    @content[:error] = nil
    @content[:images] = []
    @content[:mime_type] = nil
    @content[:headers] = {}
    @content[:links] = {}
  end

  def set_content_to_error(url, error_message, mime_type)
    reset_content_to_blank
    @content[:url] = url
    @content[:response_time] = Time.now.to_f - @request_time
    @content[:mime_type] = mime_type
    @content[:error] = error_message
  end

  def set_request_time
    @request_time = Time.now.to_f
  end

  # retrieves current version
  def self.version
    CobwebVersion.version
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

  private
  # checks if the mime_type is textual
  def text_content?(content_type)
    @options[:text_mime_types].each do |mime_type|
      return true if content_type.match(Cobweb.escape_pattern_for_regex(mime_type))
    end
    false
  end

  def set_additional_options
    @options[:text_mime_types] = ["text/*", "application/xhtml+xml"] if @options[:text_mime_types].nil?
  end

end

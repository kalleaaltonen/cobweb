#handles the response object from Typhoeus, giving us the option
# we need for a content response
class Response
  attr_accessor :r, :options

  def initialize(response, options)
    @r = response
    @options = options
    set_internal_urls_if_empty
    true
  end

  def to_hash
    {
      url: url,
      status_code: status_code,
      body: body,
      length: content_length,
      headers: headers,
      mime_type: mime_type,
      character_set: character_set,
      location: location,
      ip: ip,
      redirect_count: redirect_count,
      response_time: response_time,
      images: images,
      links: links
    }
  end

  # if there isn't any internal URLs passed, we set the host as the root
  # for internal URLs for parsing the array
  def set_internal_urls_if_empty
    if @options[:internal_urls].nil? || Array(@options[:internal_urls]).length == 0
      @options[:internal_urls] = []
      @options[:internal_urls] << "http://#{host}/*"
      @options[:internal_urls] << "https://#{host}/*"
    end
  end

  def ip
    @r.primary_ip
  end

  def redirect_count
    @r.redirect_count
  end

  def response_time
    @r.total_time
  end

  def url
    @r.url
  end

  def uri
    @uri ||= URI.parse(url)
  end

  def host
    uri.host
  end

  def status_code
    code
  end

  def code
    @r.code
  end

  def body
    @r.body
  end

  def content_length
    if headers["Content-Length"]
      headers["Content-Length"].to_i
    else
      body.length
    end
  end

  def headers
    @r.headers_hash
  end

  def mime_type
    @mime_type ||= headers["Content-Type"].to_s.split(";")[0].strip unless headers["Content-Type"].nil?
  end

  def location
    headers["Location"]
  end

  def character_set
    @character_set ||= begin
      if !headers["Content-Type"].nil? && headers["Content-Type"].include?(";")
        charset = headers["Content-Type"][headers["Content-Type"].index(";")+2..-1] if !headers["Content-Type"].nil? and headers["Content-Type"].include?(";")
        charset = charset[charset.index("=")+1..-1] if charset and charset.include?("=")
      end
      charset
    end
  end

  def links
    @links ||= begin
      linkz = link_parser.link_data
      linkz[:external] = link_parser.external_links
      linkz[:internal] = link_parser.internal_links
      linkz
    end
  end

  # parse data for links
  def link_parser
    @link_parser ||= ContentLinkParser.new(url, body, @options)
  end

  def images
    @images ||= begin
      imgs = []
      Array(link_parser.full_link_data.select {|link| link["type"] == "image"}).each do |inbound_link|
        inbound_link["link"] = UriHelper.parse(inbound_link["link"])
        imgs << inbound_link
      end
      imgs
    end
  end

end

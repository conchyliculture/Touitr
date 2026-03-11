require 'json'
require 'mechanize'
require 'mustache'

require "logger"
require 'net/http'
require 'nokogiri'
require 'pry'
require 'time'
require 'timeout'
require 'zip'

HEADER_TEMPLATE = File.read("templates/header.mustache")
POST_TEMPLATE = File.read("templates/post.mustache")
INDEX_TEMPLATE = File.read("templates/index.mustache")
FOOTER_TEMPLATE = File.read("templates/footer.mustache")

class TouitrParser
  CACHE_DIR = '.cache'.freeze
  IMAGES_DIR_NAME = 'images'.freeze
  TWITTER_HOST = 'fxtwitter.com'.freeze

  attr_accessor :archive_owner

  def initialize(zip_file, destination_directory, config)
    raise StandardError, "Please specify an existing zipfile" unless zip_file

    @config = config

    @log = Logger.new($stdout)
    @log.level = $VERBOSE ? Logger::DEBUG : Logger::WARN

    @destination_directory = destination_directory
    unless Dir.exist?(@destination_directory)
      Dir.mkdir(@destination_directory)
    end

    @posts_directory = File.join(destination_directory, 'post')
    unless Dir.exist?(@posts_directory)
      Dir.mkdir(@posts_directory)
    end

    @pics_directory = File.join(@destination_directory, IMAGES_DIR_NAME)

    unless File.exist?(@pics_directory)
      Dir.mkdir(@pics_directory)
    end

    @zip_file = zip_file
    @zip = Zip::File.open(@zip_file)

    unless Dir.exist?(CACHE_DIR)
      Dir.mkdir(CACHE_DIR)
    end

    @archive_owner = {}

    @tco_links_cache_path = File.join(CACHE_DIR, 'links')
    @tco_links_cache = {}
    if File.exist?(@tco_links_cache_path)
      begin
        @tco_links_cache = JSON.parse(File.read(@tco_links_cache_path))
      rescue StandardError => e
        @log.error "Error parsing cache file #{@tco_links_cache_path}. Consider deleting the file."
        raise e
      end
    end

    @og_cache_path = File.join(CACHE_DIR, 'meta-og')
    @og_cache = {}
    if File.exist?(@og_cache_path)
      @og_cache = JSON.parse(File.read(@og_cache_path, encoding: Encoding::UTF_8))
    end

  end

  def update_og_cache(url, type, value)
    (@og_cache[url] ||= {})[type] = value
    f = File.open(@og_cache_path, 'w')
    f.write(JSON.pretty_generate(@og_cache))
    f.close
  end

  def pull_og_data(url)
    if @og_cache[url]
      return @og_cache[url]
    end

    res = {}
    begin
      mechanize = Mechanize.new
      mechanize.user_agent_alias = "Windows Edge"
      Timeout.timeout(5) {
        resp = Nokogiri::HTML.parse(mechanize.get(url).body)
        res = Hash[resp.css('head meta').select { |meta| (meta['property'] || '').start_with?('og:') }.map { |meta| [meta['property'], meta['content']] }]
      }
    rescue Socket::ResolutionError, Mechanize::ResponseCodeError, Timeout::Error => e
      @log.warn "Error #{e.class} when triyng to pull metadata from #{url}"
    end
    res.each do |k, v|
      update_og_cache(url, k, v)
    end
    return res
  end

  def update_tco_cache(from, to)
    @tco_links_cache[from] = to
    f = File.open(@tco_links_cache_path, 'w')
    f.write(JSON.pretty_generate(@tco_links_cache))
    f.close
  end

  def generate_post_opengraph(data)
    og = ""

    pp data
    if data['media']
      if data['media'][0]['type'] == 'video'
        v = data['media'][0]
        og += """
      <meta property=\"og:type\" content=\"video.other\" />
      <meta property=\"og:video\" content=\"#{@config['base_url']}/#{v['url']}\" />
      <meta property=\"og:video:secure_url\" content=\"#{@config['base_url']}/#{v['url']}\" />
      <meta property=\"og:video:type\" content=\"video/mp4\" />
      <meta property=\"og:video:width\" content=\"640\" />
      <meta property=\"og:video:height\" content=\"360\" />
      <meta property=\"og:image\" content=\"#{v['thumbnail']}\" />
      """
      elsif data['media'][0]['type'] == 'image'
      end
    end
    return og

  end

  def resolve_tco(url)
    return @tco_links_cache[url] if @tco_links_cache[url]

    @log.info("Resolving #{url}.... ")
    resp = Net::HTTP.get_response(URI(url))
    if resp.code == "301"
      loc = resp['location']
      loc = loc.force_encoding('utf-8')
      @log.info("... To #{loc}")
      update_tco_cache(url, loc)
      return resp['location']
    else
      raise StandardError, "Unexpected response code #{resp.code} from trying to resolve link #{url}"
    end
  end

  def build_twitter_link(handle: nil, tweet_id: nil)
    return "https://#{TWITTER_HOST}/#{handle}/status/#{tweet_id}"
  end

  def get_archive_username()
    json = javascript_to_json('data/account.js')
    json[0]['account']['username']
  end

  def get_archive_userid()
    json = javascript_to_json('data/account.js')
    json[0]['account']['accountId']
  end

  def get_archive_displayname()
    json = javascript_to_json('data/account.js')
    json[0]['account']['accountDisplayName']
  end

  def get_archive_avatar()
    json = javascript_to_json('data/profile.js')
    url = json[0]['profile']['avatarMediaUrl']

    if url.start_with?("https://")
      frag = url.split('/')
      prof_file = @zip.glob("data/profile_media/*#{frag[-1]}*")[0]
      url = File.join(@pics_directory, 'profile.jpg')
      extract_file(prof_file, File.join(@pics_directory, 'profile.jpg'))
      return File.join(IMAGES_DIR_NAME, 'profile.jpg')
    end
    return url
  end

  def find_media(pattern)
    results = @zip.glob("data/tweets_media/*#{pattern}*")

    if results.size == 1
      return results[0].name
    elsif results.empty?
      @log.warn "Could not find a media with pattern *#{pattern}* in the archive"
      return nil
    else
      raise StandardError, "Found more than one media with pattern *#{pattern}*"
    end
  end

  def extract_file(zip_path, destination)
    if File.exist?(destination)
      @log.debug "File #{destination} already exists, skipping extraction"
      return
    end
    File.new(destination, 'w+').write(@zip.read(zip_path))
  end

  def javascript_to_json(js_file)
    tweets_file = @zip.read(js_file)
    j = JSON.parse(tweets_file.sub(/\A[^\[{]*=/, '').strip.chomp(';'))
    return j
  end

  def format_number(num)
    return "#{(num.to_i / 1_000.0).round(1)}K" if num.to_i >= 1_000

    num.to_s
  end

  def generate_post_file(post)
    has_media = post["media"] && !post["media"].empty?
    media_grid_class = has_media && post["media"].length > 1 ? "grid-#{post['media'].length}" : ""

    processed_media = []
    if has_media
      processed_media = post["media"].map do |m|
        # Mustache needs explicit booleans for conditionals
        is_image = m["type"] == 'image' || m["type"] != 'video' # default fallback to image
        is_video = m["type"] == 'video'

        m.merge(is_image: is_image, is_video: is_video)
      end
    end

    processed_content = post["content"]

    view_data = {
      base_url: @config["base_url"],
      id: post["id"],
      isRetweet: post["isRetweet"],
      retweetedBy: post["retweetedBy"],
      replyTo: post["replyTo"],
      replyToAuthor: post["replyToAuthor"],
      author: post["author"],
      author_short: post["author"].to_s[1, 3],
      handle: post["handle"],
      avatar: post["avatar"],
      full_timestamp: format_full_timestamp(post["timestamp"]),
      formatted_date: format_date(post["timestamp"]),
      processedContent: processed_content,
      link: post["link"],
      has_media: has_media,
      media_grid_class: media_grid_class,
      media: processed_media,
      formatted_retweets: format_number(post["retweets"]),
      formatted_likes: format_number(post["likes"])
    }

    # 4. Render!
    html_output = Mustache.render(
      HEADER_TEMPLATE, {
        'handle' => @archive_owner['handle'],
        'isPost' => true,
        'base_url' => @config['base_url'],
        'post_opengraph' => generate_post_opengraph(post)
      }
    )
    html_output += "\n"
    html_output += Mustache.render(POST_TEMPLATE, view_data)
    html_output += "\n"
    html_output += Mustache.render(FOOTER_TEMPLATE, @config)

    f = File.new(File.join(@posts_directory, "#{post['id']}.html"), 'w')
    f.write(html_output)
    f.close

  end

  def self.highlight_text(text, query)
    return text if query.nil? || query.empty?
    # Simple regex substitution matching the JS logic
    text.gsub(/(#{Regexp.escape(query)})/i, '<span class="highlight">\1</span>')
  end

  def format_date(timestamp)
    # Placeholder: Implement your Ruby date formatting here
    Time.parse(timestamp).strftime('%b %-d')
  end

  def format_full_timestamp(timestamp)
    # Placeholder: Implement your Ruby full date formatting here
    Time.parse(timestamp).strftime('%b %-d, %Y, %I:%M %p')
  end

  def clean_tweet_content(tweet)
    tweet['full_text'] = tweet['full_text'].gsub(/https:\/\/t.co\/[^\s]{10}/) do |x|
      d = resolve_tco(x)
      "<a href='#{d}'>#{d}</a>"
    end

    tweet['entities']['user_mentions'].each do |um|
      tweet['full_text'].gsub!("@#{um['screen_name']}", "<a href='https://twitter.com/#{um['screen_name']}'>@#{um['screen_name']}</a>")
    end

    if tweet['extended_entities']
      tweet['extended_entities']['media'].each do |m|
        # We don't need the link to the media
        tweet['full_text'].gsub!(m['expanded_url'].gsub('x.com', 'twitter.com'), '')
      end
    end

    tweet['full_text'].gsub!(/#([^\s]+)/).each do
      hashtag = Regexp.last_match(1)
      "<a href='https://twitter.com/hashtag/#{hashtag}'>##{hashtag}</a>" # rubocop:disable Lint/Void
    end

    tweet['full_text'].gsub!("\n", "<br/>")
    return tweet['full_text']
  end

  def tweets_to_json
    @archive_owner = {
      'handle' => get_archive_username(),
      'displayname' => get_archive_displayname(),
      'avatar' => get_archive_avatar(),
      'id' => get_archive_userid()
    }
    res = []
    all_tweets = javascript_to_json('data/tweets.js')
    @log.info("Will convert #{all_tweets.size} tweets")
    all_tweets[0..20].each do |t|
      tweet = t['tweet']

      begin
        info = {
          'avatar' => @archive_owner['avatar'],
          'replies' => 0,
          'retweets' => tweet['retweet_count'],
          'likes' => tweet['favorite_count'],
          'author' => @archive_owner['displayname'],
          'handle' => @archive_owner['handle'],
          "id" => tweet['id'],
          "timestamp" => tweet['created_at'],
          "type" => tweet['type'] || 'default'
        }

        if tweet['full_text'].start_with?('RT @')
          info['isRetweet'] = true
          info['retweetedBy'] = @archive_owner['displayname']
          info['avatar'] = ''
          info['author'] = tweet['full_text'].scan(/RT @([^\s]+):/)[0][0]
          info['handle'] = info['author']
          tweet['full_text'] = tweet['full_text'].delete_prefix("RT @#{info['author']}: ")
        elsif tweet['in_reply_to_status_id'] =~ /^\d+$/
          reply_to_id = tweet['in_reply_to_user_id_str']
          if reply_to_id == @archive_owner['id']
            info["replyTo"] = build_twitter_link(handle: @archive_owner['handle'], tweet_id: tweet['in_reply_to_status_id'])
            info["replyToAuthor"] = @archive_owner['handle']
          else
            reply_to_ent = tweet['entities']['user_mentions'].select { |um| um['id'] == reply_to_id }[0]
            if reply_to_ent
              reply_to_handle = reply_to_ent['screen_name']
              info["replyTo"] = build_twitter_link(handle: reply_to_handle, tweet_id: tweet['in_reply_to_status_id'])
              info["replyToAuthor"] = tweet['in_reply_to_screen_name']
            elsif tweet['full_text'].start_with?('@')
              reply_to_handle = tweet['full_text'].scan(/^@([^ ]+)/)[0][0]
              tweet['full_text'] = tweet['full_text'].delete_prefix("@#{reply_to_handle} ")
              info["replyTo"] = build_twitter_link(handle: reply_to_handle, tweet_id: tweet['in_reply_to_status_id'])
              info["replyToAuthor"] = tweet['in_reply_to_screen_name']
            else
              @log.warn "Couldn't find who this tweet was a reply to : #{tweet['id_str']}, most likely User with id #{tweet['in_reply_to_user_id']} have deleted their account"
            end
          end
        end

        if tweet['extended_entities']
          info['media'] = tweet['extended_entities']['media'].map do |m|
            item = {}
            tweet['entities']['urls'].reject! { |u| m['url'] == u['url'] }
            tweet['full_text'].gsub!(/ #{m['url']}$/, "")
            case m['type']
            when 'photo'
              item['type'] = 'photo'
              m_url = m['media_url_https']
              m_zip_path = find_media("#{tweet['id']}*#{m_url.split('/')[-1]}*")
            when 'video'
              item['type'] = 'video'
              m_zip_path = m['video_info']['variants'].map { |x| x['url'] }.select { |u| u =~ /\/vid\// }.map { |x| find_media("#{tweet['id_str']}*#{x.split('/').select { |p| p =~ /^[a-zA-Z\-_0-9]+\....(\?.+)?$/ }[0].split('.')[0]}") }.compact[0]
              item['thumbnail'] = m['media_url']
            when 'animated_gif'
              item['type'] = 'video'
              m_zip_path = find_media(tweet['id_str'])
            else
              raise StandardError, "Unsupported extended_entities media type #{m['type']}"
            end
            dest_image_filename = File.basename(m_zip_path)
            extract_file(m_zip_path, File.join(@pics_directory, dest_image_filename))
            item['url'] = "/#{IMAGES_DIR_NAME}/#{dest_image_filename}"

            item
          end

        elsif tweet['entities']['media']
          info['media'] = tweet['entities']['media'].map do |m|
            m_url = m['media_url_https']
            m_zip_path = find_media(m_url.split('/')[-1])
            dest_image_filename = File.basename(m_zip_path)
            extract_file(m_zip_path, File.join(@pics_directory, dest_image_filename))

            "/#{IMAGES_DIR_NAME}/#{dest_image_filename}"
          end
        end

        if tweet['full_text'] =~ / (https:\/\/t.co\/.{10})$/ and not info['isRetweet'] and not info['replyTo']
          # This is a QRT, but we can't get info from the tweet it's a QRT of so, treating as a replyto
          url = Regexp.last_match(1)
          qrt_from_url = tweet['entities']['urls'].select { |u| u['url'] == url }[0]['expanded_url']
          info["replyTo"] = qrt_from_url
          info["replyToAuthor"] = qrt_from_url.split('/')[3]
        end

        info['content'] = clean_tweet_content(tweet)

        if (tweet['entities'] || {})['urls'] and not tweet['entities']['urls'].empty?

          url = tweet['entities']['urls'][0]['expanded_url']

          if not url.start_with?("https://x.com/") and
             not url.start_with?("https://twitter.com") and
             not url.start_with?("https://goto.ninja") and
             not url.start_with?("http://goto.ninja")

            begin
              og = pull_og_data(url)
              unless og.empty?
                info['link'] = {
                  'url' => url,
                  'domain' => URI.parse(url).host
                }
                info['link']['title'] = og['og:title'] || og['og:site_name'] || info['link']['domain']
                info['link']['description'] = og['og:description'] || ''
                if og['og:image']
                  info['link']['image'] = og['og:image']
                end
              end
            rescue URI::InvalidURIError, OpenSSL::SSL::SSLError
            end
          end
        end
      rescue StandardError => e
        puts e.backtrace
        puts "#{e} #{e.class}"
        # binding.pry
        raise e
      end

      generate_post_file(info)

      res << info
    end

    out = File.open("#{@destination_directory}/posts.json", 'w')
    out.write(JSON.pretty_generate(res))
    out.close
  end
end

config  = JSON.parse(File.read("config.json"))

dest_dir = ARGV[1]
t = TouitrParser.new(ARGV[0], dest_dir, config)
t.tweets_to_json

FileUtils.cp('assets/styles.css', File.join(dest_dir, '/'))

index = Mustache.render(
  HEADER_TEMPLATE, {
    'handle' => t.archive_owner['handle'],
    'base_url' => config['base_url']
  }
)
index += Mustache.render(INDEX_TEMPLATE)
index += Mustache.render(FOOTER_TEMPLATE)

i = File.open(File.join(dest_dir, 'index.html'), 'w')
i.write(index)
i.close

script = File.read('assets/script.js')
script.gsub!('PLACEHOLDER_POST_TEMPLATE', File.read('templates/post.mustache'))
script.gsub!('PLACEHOLDER_BASE_URL', config['base_url'])
i = File.open(File.join(dest_dir, 'script.js'), 'w')
i.write(script)
i.close

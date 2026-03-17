require 'json'
require "logger"
require 'marcel'
require 'mechanize'
require 'mime-types'
require 'mustache'
require 'net/http'
require 'nokogiri'
require 'optparse'
require 'progressbar'
require 'time'
require 'timeout'
require 'zip'

require './lib/utils'

HEADER_TEMPLATE = File.read("templates/header.mustache")
POST_TEMPLATE = File.read("templates/post.mustache")
INDEX_TEMPLATE = File.read("templates/index.mustache")
FOOTER_TEMPLATE = File.read("templates/footer.mustache")

class ProgressBar
  class Base
    attr_accessor :logger

    alias original_initialize initialize
    def initialize(*args)
      @logger = Logger.new self
      original_initialize(*args)
    end
  end

  class Logger < ::Logger
    alias original_initialize initialize
    def initialize(progress_bar) # rubocop:disable Lint/MissingSuper
      @progress_bar = progress_bar
      original_initialize nil
    end

    def add(severity, message = nil, progname = nil, &_block)
      severity ||= UNKNOWN
      return true if severity < @level

      progname ||= @progname
      if message.nil?
        if block_given?
          message = yield
        else
          message = progname
          progname = @progname
        end
      end
      @progress_bar.log format_message(format_severity(severity), now, progname, message)
      true
    end
  end
end

class TouitrParser
  CACHE_DIR = '.cache'.freeze
  IMAGES_DIR_NAME = 'images'.freeze

  attr_accessor :archive_owner

  def initialize(zip_file, destination_directory, base_url)
    raise StandardError, "Please specify an existing zipfile" unless zip_file

    @base_url = base_url
    @progress_bar = nil

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
        puts "Error parsing cache file #{@tco_links_cache_path}. Consider deleting the file."
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
    content_url = Utils.join_url(Utils.join_url(@base_url, 'post'), "#{data['id']}.html")
    og = "
    <meta property=\"og:url\" content=\"#{content_url}\">
    <meta property=\"og:description\" content=\"#{Nokogiri::HTML.parse(data['content']).text}\">
    "

    if data['media']
      case data['media'][0]['type']
      when 'video'
        v = data['media'][0]
        og += "
    <meta property=\"og:video\" content=\"#{v['media_url']}\">
    <meta property=\"og:video:secure_url\" content=\"#{v['media_url']}\">
    <meta property=\"og:video:type\" content=\"#{v['media_type']}\">
    <meta property=\"og:image\" content=\"#{v['thumbnail']}\">
    <meta property=\"twitter:card\" content=\"player\">
      "
      when 'photo'
        og += "
    <meta name=\"twitter:card\" content=\"summary_large_image\">
    "
        data['media'].each do |i|
          og += "
    <meta property=\"og:type\" content=\"image\">
    <meta property=\"og:image\" content=\"#{i['media_url']}\">
    "
        end

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
      loc = loc.encode('UTF-8', invalid: :replace, undef: :replace)
      @log.info("... To #{loc}")
      update_tco_cache(url, loc)
      return resp['location']
    else
      raise StandardError, "Unexpected response code #{resp.code} from trying to resolve link #{url}"
    end
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
      return
    end

    File.new(destination, 'w+').write(@zip.read(zip_path))
  end

  def javascript_to_json(js_file)
    tweets_file = @zip.read(js_file)
    j = JSON.parse(tweets_file.sub(/\A[^\[{]*=/, '').strip.chomp(';'))
    return j
  end

  def generate_post_file(post)
    has_media = post["media"] && !post["media"].empty?
    media_grid_class = has_media && post["media"].size > 1 ? "grid-#{post['media'].size}" : ""

    processed_media = []
    if has_media
      processed_media = post["media"].map do |m|
        # Mustache needs explicit booleans for conditionals
        is_image = m["type"] == 'image' || m["type"] != 'video' # default fallback to image
        is_video = m["type"] == 'video'

        m.merge(is_image: is_image, is_video: is_video)
      end
    end

    avatar_url = nil
    if post["handle"] == @archive_owner['handle']
      avatar_url = @archive_owner['avatar_url']
    else
      avatar_url = post["avatar"] ? Utils.join_url(@base_url, post['avatar']) : nil
    end

    view_data = {
      base_url: @base_url,
      id: post["id"],
      post_url: Utils.join_url(Utils.join_url(@base_url, 'post'), "#{post['id']}.html"),
      isRetweet: post["isRetweet"],
      retweetedBy: post["retweetedBy"],
      replyTo: post["replyTo"],
      replyToAuthor: post["replyToAuthor"],
      author: post["author"],
      author_short: post["author"].to_s[0, 2],
      avatar_url: avatar_url,
      handle: post["handle"],
      avatar: post["avatar"],
      full_timestamp: Utils.format_full_timestamp(post["timestamp"]),
      formatted_date: Utils.format_date(post["timestamp"]),
      processedContent: post["content"],
      link: post["link"],
      has_media: has_media,
      media_grid_class: media_grid_class,
      media: processed_media,
      formatted_retweets: Utils.format_number(post["retweets"]),
      formatted_likes: Utils.format_number(post["likes"])
    }

    # 4. Render!
    html_output = Mustache.render(
      HEADER_TEMPLATE, {
        'handle' => @archive_owner['handle'],
        'isPost' => true,
        'stylesheet_url' => Utils.join_url(@base_url, 'styles.css'),
        'mustache_url' => Utils.join_url(@base_url, 'mustache.js'),
        'base_url' => @base_url,
        'post_opengraph' => generate_post_opengraph(post)
      }
    )
    html_output += "\n"
    html_output += Mustache.render(POST_TEMPLATE, view_data)
    html_output += "\n"
    html_output += Mustache.render(FOOTER_TEMPLATE, {})

    f = File.new(File.join(@posts_directory, "#{post['id']}.html"), 'w')
    f.write(html_output)
    f.close
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

  def parse_archive(twitter_host= Utils::DEFAULT_TWITTER_HOST)
    @archive_owner = {
      'handle' => get_archive_username(),
      'displayname' => get_archive_displayname(),
      'avatar_url' => Utils.join_url(@base_url, get_archive_avatar()),
      'id' => get_archive_userid()
    }

    res = []
    all_tweets = javascript_to_json('data/tweets.js')
    @progress_bar = ProgressBar.create(total: all_tweets.size, title: "Converting tweets", format: "%t %c/%C |%b>%i| %e")
    @log = @progress_bar.logger
    @log.level = $VERBOSE ? Logger::DEBUG : Logger::WARN
    @log.info("Will convert #{all_tweets.size} tweets")
    all_tweets.each do |t|
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
            info["replyTo"] = Utils.build_twitter_link(handle: @archive_owner['handle'], tweet_id: tweet['in_reply_to_status_id'], twitter_host: twitter_host)
            info["replyToAuthor"] = @archive_owner['handle']
          else
            reply_to_ent = tweet['entities']['user_mentions'].select { |um| um['id'] == reply_to_id }[0]
            if reply_to_ent
              reply_to_handle = reply_to_ent['screen_name']
              info["replyTo"] = Utils.build_twitter_link(handle: reply_to_handle, tweet_id: tweet['in_reply_to_status_id'], twitter_host: twitter_host)
              info["replyToAuthor"] = tweet['in_reply_to_screen_name']
            elsif tweet['full_text'].start_with?('@')
              reply_to_handle = tweet['full_text'].scan(/^@([^ ]+)/)[0][0]
              tweet['full_text'] = tweet['full_text'].delete_prefix("@#{reply_to_handle} ")
              info["replyTo"] = Utils.build_twitter_link(handle: reply_to_handle, tweet_id: tweet['in_reply_to_status_id'])
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
            dest_image_path = File.join(@pics_directory, dest_image_filename)
            extract_file(m_zip_path, dest_image_path)
            item['media_type'] = Utils.get_media_type(dest_image_path)
            item['media_url'] = Utils.join_url(@base_url, "/#{IMAGES_DIR_NAME}/#{dest_image_filename}")

            item
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
      @progress_bar.increment
    end

    out = File.open("#{@destination_directory}/posts.json", 'w')
    out.write(JSON.pretty_generate(res))
    out.close
  end
end

def generate_index(params)
  index_html = Mustache.render(HEADER_TEMPLATE, params)
  index_html += Mustache.render(INDEX_TEMPLATE, params)
  index_html += Mustache.render(FOOTER_TEMPLATE, params)
  return index_html
end

def generate_scriptjs(params)
  script = File.read('assets/script.js')
  script.gsub!('PLACEHOLDER_POST_TEMPLATE', File.read('templates/post.mustache'))
  script.gsub!('PLACEHOLDER_BASE_URL', params['base_url'])
end

config_file = "config.json"
config = {}

base_url = nil

parser = OptionParser.new
parser.on('-c CONFIG_FILE', '--config CONFIG_FILE', '(Optional) Point to a specific config.json file') do |value|
  config_file = value
end
if File.exist?(config_file)
  config = JSON.parse(File.read(config_file))
end

output_directory = config['output_directory'] || '/tmp/touitr'
archive_file = config['archive_file']
twitter_host = config['twitter_host'] || 'twitter.com'

parser.on('-d DEST_DIR', '--destination DEST_DIR', 'Output directory for generated files') do |value|
  output_directory = value
end
parser.on('-z ARCHIVE', '--archive ARCHIVE', 'The zip file from your Twitter export') do |value|
  archive_file = value
end
parser.on('-b BASE_URL', '--base_url BASE_URL', 'The base URL where the generated files will be hosted. ie: https://your.website.test/somewhere') do |value|
  base_url = value
end
parser.on('-t TWITTER_HOST', '--twitter_host TWITTER_HOST', 'The Twitter host to use for links. ie: fxtwitter.com') do |value|
  twitter_host = value
end

parser.parse!

unless base_url
  puts "You need to specify a base_url. Set it to https://your.website.test/somewhere/"
  puts parser.help
  exit
end

unless File.exist?(archive_file.to_s)
  puts "Archive file '#{archive_file}' doesn't seem too exist"
  puts parser.help
  exit
end

unless File.directory?(output_directory)
  FileUtils.mkdir_p(output_directory)
end

t = TouitrParser.new(archive_file, output_directory, base_url)
t.parse_archive(twitter_host: twitter_host)

FileUtils.cp('assets/styles.css', File.join(output_directory, '/'))
FileUtils.cp('assets/mustache.js', File.join(output_directory, '/'))

index = File.open(File.join(output_directory, 'index.html'), 'w')
index.write(generate_index(
              {
                'handle' => t.archive_owner['handle'],
                'base_url' => base_url,
                'mustache_url' => Utils.join_url(base_url, 'mustache.js'),
                'stylesheet_url' => Utils.join_url(base_url, 'styles.css'),
                'scriptjs_url' => Utils.join_url(base_url, 'script.js')
              }
            ))
index.close()

script = File.open(File.join(output_directory, 'script.js'), 'w')
script.write(generate_scriptjs(
               {
                 'base_url' => base_url
               }
             ))
script.close

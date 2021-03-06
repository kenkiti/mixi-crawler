# -*- coding: utf-8 -*-
#! /usr/bin/env ruby
# 
# Mixi photo crawler 
# 
# * for use
# sudo gem install mechanize
# sudo gem install pit
# sudo gem install activerecord(rails)
# sudo gem install sqlite3-ruby
# 

require 'logger'
require 'kconv'

require 'rubygems'
require 'mechanize'
require 'pit'
require 'active_record'

class LogFormatter
  def call(severity, time, progname, msg)
    "[%s] [%s] %s\n" % [format_datetime(time), severity, msg2str(msg)]
  end

  private

  def format_datetime(time)
    time.strftime "%Y-%m-%d %H:%M:%S"
  end

  def msg2str(msg)
    case msg
    when ::String
      msg
    when ::Exception
      "#{msg.message} (#{msg.class})\n" << (msg.backtrace || []).join("\n")
    else
      msg.inspect
    end
  end
end

class Logger
  private
  # Rails overrides this method so that it can customize the format
  # of it's logs.
  def format_message(*args)
    old_format_message(*args)
  end
end

module DB
  class Id < ActiveRecord::Base; end
  class Queue < ActiveRecord::Base; end

  def self.initialize_database
    ActiveRecord::Base.establish_connection(
      :adapter => 'sqlite3',
      :database => 'id_queue.db',
      :timeout => 5000
      )
    create_tables unless DB::Id.table_exists?
  end

  def self.create_tables
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table "ids", :force => true do |t|
        t.column "mixiid", :string
        t.timestamps
      end
      create_table "queues", :force => true do |t|
        t.column "mixiid", :string
        t.timestamps
      end
    end
  end
end

module Crawler
  class ImageSaver < WWW::Mechanize::File
    def initialize(uri=nil, response=nil, body=nil, code=nil)
      super(uri, response, body, code)
    end
    
    def save(file_path)
      File.open(file_path, 'wb') {|h| h.puts body } unless File.exists?(file_path)
    end
  end
  
  class Mixi
    def initialize(opt)
      @agent = WWW::Mechanize.new
      @agent.user_agent_alias = 'Windows IE 7'
      @agent.log = opt[:logger]
#       @agent.log = Logger.new(opt[:logfile] || STDOUT)
#       @agent.log.level = Logger::INFO
#       @agent.log.formatter = LogFormatter.new
      @agent.redirect_ok = true
      @agent.max_history = 1
      @agent.pluggable_parser['image/jpeg'] = ImageSaver
      @path = opt[:path] || "image"
      Dir::mkdir(@path) unless FileTest::directory?(@path)
    end
    
    def login
      @agent.log.info "logging..."
      config = Pit.get("mixi.jp.2", :require => { 
          "username" => "your email in mixi",
          "password" => "your password in mixi"
        })
      page = get_page('http://mixi.jp/')
      form = page.forms[0]
      form.field_with(:name => 'email').value = config['username']
      form.field_with(:name => 'password').value = config['password']
      form.field_with(:name => 'next_url').value = '/home.pl'
      page = @agent.submit(form, form.buttons.first)
      sleep 5
      self
    end

    def logout
      page = get_page('http://mixi.jp/')
      uri = page.link_with(:text => /ログアウト/)
      return if uri.nil?
      page = @agent.click(uri) 
      page
    end
    
    def get_page(uri, reffer=nil)
      @agent.get(uri, reffer)
    rescue TimeoutError
      @agent.log.warn 'Connection timeout.'; nil
    rescue WWW::Mechanize::ResponseCodeError => e
      @agent.log.warn "#{e.message} #{uri}"; nil
    else
      sleep 3 * rand(10)
      @agent.page
    end
    
    def show_photo(id)
      page = get_page("http://mixi.jp/show_photo.pl?id=#{id}")
      return nil if page.nil?

      page.root.search("html body div").inject([]) {|r, e|
        r << $1 if /background\-image\:url\((.*)\)/ =~ e['style']; r
      }.each {|url|
        file_path = File.join(@path, url.split("/")[-1])
        unless File.exists?(file_path)
          if get_page(url) #, @agent.visited_page(uri))
            @agent.page.save(file_path)
          end
        end
      }
    end

    def check_ban(page)
      if page.body.split("\n")[0] == "<html>"
        @agent.log.warn "crawler banned. wait for 30 minutes."
        logout
        sleep 1800
        login
      end
    end
    
    def list_friend(id)
      friends = get_page("http://mixi.jp/list_friend.pl?id=#{id}")
      check_ban(friends)
      ids = []
      while friends
        ids += friends.links.inject([]) {|xs, x| xs << $1 if /^show_friend.pl\?id=(\d+)/ =~ x.href; xs }
        uri = friends.link_with(:text => /次を表示/)
        friends = uri ? @agent.click(uri) : nil
        sleep 2
      end
      ids.uniq
    end
  end

  def list_request
    page = get_page("http://mixi.jp/list_request.pl")
    # 承認ボタンクリック
    form = page.forms[1]
    if form.nil?
      @agent.log.warn "no approval button."
      return nil
    end


    page.form_with(:action => "accept_request.pl") do |f|
      # 承認ボタンクリック
      # 2009/10/01 ミクシィの仕様がかわり、hidden された post_key を送る必要がある。
      # <input type="hidden" value= "23589182" name="id">
      # <input type="hidden" value= "4903f9ea231a7783dabbd49790b48a90fce5f28a" name="post_key">
      # <input type="hidden" value= "1" name="page">
      # <input type="hidden" value= "1" name="anchor">
      form['id'] = $1 if /<input type="hidden" value= "(.+)" name="id">/ =~ page.body
      form['post_key'] = $1 if /<input type="hidden" value= "(.+)" name="post_key">/ =~ page.body
      form['page'] = $1 if /<input type="hidden" value= "(.+)" name="page">/ =~ page.body
      form['anchor'] = $1 if /<input type="hidden" value= "(.+)" name="anchor">/ =~ page.body
      page = @agent.submit(form, form.buttons.first)
      
      # 送信コメント欄
      form = page.form_with(:name => 'replyForm')
      if form.nil?
        @agent.log.warn "invalid user id."
        # 既に退会されたユーザーか、存在しないIDです。
        page = get_page("http://mixi.jp/list_request.pl")
        form = page.forms[2]
        page = @agent.submit(form, form.buttons.first) # 拒否する
        form = page.forms[1]
        page = @agent.submit(form, form.buttons.first) # 本当に拒否する
        return page.body
      end
      body = form.field_with(:name => 'body')
      if form.nil?
        @agent.log.warn "no textarea."
        return nil
      end
      if /おねがいし|お願いし/ =~ body.value
        body.value +=  "\nこちらこそょろしくおねがぃします[m:66]"
      elsif /よろしく|宜しく/ =~ body.value
        body.value +=  "\nこちらこそょろしくね[m:66]"
      else
        body.value +=  "\nょろしくね[m:66]"
      end
      
      puts body.value
      
      # <input type="hidden" name="post_key" value="b7272fd1c8b9ca71c75821dfe936f045bb86ada0">
      form['post_key'] = $1 if /<input type="hidden" name="post_key" value= "(.+)">/ =~ page.body
      page = @agent.submit(form, form.buttons.first)
      return page.body
    end

    # 「マイミクシィが1000人を超えているため、承認できません。
    # お手数ですが｢拒否する｣ボタンを押すか、1000人以下になるまでお待ち下さい。」の処理
    page.form_with(:action => "reject_request.pl") do |f|
      puts f.buttons.first.value
      page = @agent.submit(f, f.buttons.first) #if form.buttons.first.value =~ /拒否する/

      form = page.forms[1]
      form['post_key'] = $1 if /<input type="hidden" value= "(.+)" name="post_key">/ =~ page.body
      page = @agent.submit(form, form.buttons.first) #if form.buttons.first.value =~ /拒否する/
      puts "----> reject"
      return page.body
    end
  end

  class IdQueue
    def initialize
      DB.initialize_database
    end
    
    def push(ids)
      ids.map {|id| DB::Queue.create(:mixiid => id) }
    end
    
    def shift
      record = DB::Queue.find(:first)
      DB::Queue.delete(record.id) unless record.nil?
      record ? record.mixiid : nil
    end
    
    def visited?(id)
      visited = DB::Id.find_by_mixiid(id) ? true : false
      DB::Id.create(:mixiid => id) unless visited
      visited
    end
    
    def record_count
      DB::Queue.find(:all).length
    end
  end
end

def main(logfile)
  include Crawler
  logger = Logger.new(logfile || STDOUT)
  logger.level = Logger::INFO
  logger.formatter = LogFormatter.new
  
  q = IdQueue.new
  q.push(['14820421']) if q.record_count == 0
  
  m = Mixi.new(:path => 'image', :logger =>logger).login
  while id = q.shift
    if q.visited?(id)
      logger.info("Skip #{id}")
      next
    end
    
    q.push(m.list_friend(id))
    m.show_photo(id)
  end
end

def approve_request(logfile)
  include Crawler
  logger = Logger.new(logfile || STDOUT)
  logger.level = Logger::INFO
  logger.formatter = LogFormatter.new

  m = Mixi.new(:path => 'image', :logger =>logger).login
  while true
    break if m.list_request == nil
  end
end

# def test_logout
#   include Crawler
#   m = Mixi.new(:path => 'image').login
#   open("test.html","w").write(m.logout.body)
#   system("open test.html")
# end

if $0 == __FILE__
  require 'optparse'
  parser = OptionParser.new
  approve = nil
  logfile = nil
  parser.banner = "Usage: #{File.basename($0)} [options]"
  parser.on('-a','--approve', "approve mymiku request.") {|p| approve = true }
  parser.on("-l",'--log FILE', "output info to log file") { |p| logfile = p }
  parser.on('-h', '--help', 'Prints this message and quit.') {
    puts parser.help
    exit 0;
  }
  
  begin
    parser.parse!(ARGV)
  rescue OptionParser::ParseError => e
    $stderr.puts e.message
    $stderr.puts parser.help
    exit 1
  end

  if approve
    approve_request(logfile)
  else
    main(logfile)
  end
end

# -*- coding: utf-8 -*-
#! /usr/bin/env ruby
# 
# Mixi photo crawler 
# 
# * for use
# sudo gem install mechanize
# sudo gem install pit
# sudo gem install activerecord(rails)
# sudo gem install sqlite-ruby
# 

require 'logger'
require 'kconv'

require 'rubygems'
require 'mechanize'
require 'pit'
require 'active_record'

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
      @agent.log = Logger.new($stdout)
      @agent.log.level = Logger::INFO
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
      @agent.log.warn "no syounin.button"
      return nil
    end
    page = @agent.submit(form, form.buttons.first)

    # 送信コメント欄
    form = page.form_with(:name => 'replyForm')
    if form.nil?
      @agent.log.warn "no reply form"
      return nil
    end
    body = form.field_with(:name => 'body')
    if form.nil?
      @agent.log.warn "no textarea"
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
    page = @agent.submit(form, form.buttons.first)
    page.body
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

def main
  include Crawler
  log = Logger.new(STDOUT)
  log.level = Logger::INFO
  
  q = IdQueue.new
  q.push(['14820421']) if q.record_count == 0
  
  m = Mixi.new(:path => 'image').login
  while id = q.shift
    if q.visited?(id)
      log.info("Skip #{id}")
      next
    end
    
    q.push(m.list_friend(id))
    m.show_photo(id)
    #sleep 300 if id.to_i % 30 == 0 # wait
  end
end

def approve_request
  include Crawler
  log = Logger.new(STDOUT)
  log.level = Logger::INFO

  m = Mixi.new(:path => 'image').login
  while true
    break if m.list_request == nil
  end
end

def test_logout
  include Crawler
  m = Mixi.new(:path => 'image').login
  open("test.html","w").write(m.logout.body)
  system("open test.html")
end

if $0 == __FILE__
  require 'optparse'
  parser = OptionParser.new
  opt = {}
  parser.banner = "Usage: #{File.basename($0)} [options]"
  parser.on('-a','--approve', "approve mymiku request.") {|p| opt[:approve] = true }
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
  else
    if opt[:approve]
      approve_request
    else
      main
    end
  end
end

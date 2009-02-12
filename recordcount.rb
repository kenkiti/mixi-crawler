require 'benchmark'
require 'rubygems'
require 'sqlite3'
db = SQLite3::Database.new('id_queue.db')
Benchmark.bm do |x|
  x.report { puts "record = #{db.execute('select count(*) from ids')}" }
  x.report { puts "record = #{db.execute('select count(*) from queues')}" }
end

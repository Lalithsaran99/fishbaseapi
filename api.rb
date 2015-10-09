require 'bundler/setup'
%w(yaml json csv digest).each { |req| require req }
Bundler.require(:default)
require 'sinatra'
require_relative 'models/models'

$config = YAML::load_file(File.join(__dir__, 'config.yaml'))

$redis = Redis.new host: ENV.fetch('REDIS_PORT_6379_TCP_ADDR', 'localhost'),
                   port: ENV.fetch('REDIS_PORT_6379_TCP_PORT', 6379)

ActiveSupport::Deprecation.silenced = true
ActiveRecord::Base.establish_connection($config['db']['fb'])

class API < Sinatra::Application
  before do
    # set headers
    headers 'Content-Type' => 'application/json; charset=utf8'
    headers 'Access-Control-Allow-Methods' => 'HEAD, GET'
    headers 'Access-Control-Allow-Origin' => '*'
    cache_control :public, :must_revalidate, max_age: 60

    # use redis caching
    if $config['caching']
      @cache_key = Digest::MD5.hexdigest(request.url)
      if $redis.exists(@cache_key)
        headers 'Cache-Hit' => 'true'
        halt 200, $redis.get(@cache_key)
      end
    end

    # set correct db connection
    ActiveRecord::Base.establish_connection($config['db'][request.script_name == '/sealifebase' ? 'slb' : 'fb'])
  end

  after do
    # cache response in redis
    if $config['caching'] && !response.headers['Cache-Hit'] && response.status == 200
      $redis.set(@cache_key, response.body[0], ex: $config['caching']['expires'])
    end
  end

  # handle missed route
  not_found do
    '404 not found'
  end

  # handle other errors
  error do
    'Server error'
  end

  # default to heartbeat
  get '/' do
    redirect '/heartbeat'
  end

  # route listing route
  get '/heartbeat/?' do
    { routes: %w(
            /docs/:table?
            /heartbeat
            /mysqlping
            /comnames?<params>
            /countref?<params>
            /country?<params>
            /diet?<params>
            /ecology?<params>
            /ecosystem?<params>
            /faoareas/:id?<params>
            /faoarref/:id?<params>
            /fecundity?<params>
            /fooditems?<params>
            /genera/:id?<params>
            /intrcase?<params>
            /maturity?<params>
            /morphdat?<params>
            /morphmet?<params>
            /occurrence?<params>
            /oxygen?<params>
            /popchar?<params>
            /popgrowth?<params>
            /poplf?<params>
            /popll?<params>
            /popqb?<params>
            /poplw?<params>
            /predats?<params>
            /ration?<params>
            /refrens?<params>
            /reproduc?<params>
            /species/:id?<params>
            /spawning?<params>
            /speed?<params>
            /stocks?<params>
            /swimming?<params>
            /synonyms?<params>
            /taxa?<params>
    )}.to_json
  end

  # docs route
  get '/docs/?:table?/?' do
    table = params[:table] || 'tables'
    filename = "docs/docs-sources/#{table}.csv"
    halt not_found unless File.exists?(filename)
    hash = CSV.new(File.read(filename), headers: true).map { |row| row.to_hash }
    { count: hash.length, returned: hash.length, data: hash, error: nil }.to_json
  end

  # db status route
  get '/mysqlping/?' do
    { mysql_server_up: true, mysql_host: $config['db']['host'] }.to_json
  end

  # list fields route
  get '/listfields/?' do
    fields, exact = params[:fields], params[:exact]
    data = Models.list_fields($config['db']['database'])
    unless fields.nil?
      fields = fields.gsub(',', '|')
      fields = fields.split('|').map { |field| "^#{field}$" }.join('|') if exact
      data.keep_if { |a| a[:column_name].match(fields) }
    end
    { count: data.length, returned: data.length, data: data, error: nil }.to_json
  end

  # generate routes from the models
  Models.models.each do |model_name|
    model = Models.const_get(model_name)
    get "/#{model_name.to_s.downcase}/?#{model.primary_key ? ':id?/?' : '' }" do
      begin
        data = model.endpoint(params)
        raise Exception.new('FBApp::Error: No results found') if data.length.zero?
        { count: data.length, returned: data.length, data: data, error: nil }.to_json
      rescue Exception => e
        { count: 0, returned: 0, data: nil, error: { message: e.message }}.to_json
      end
    end
  end
end

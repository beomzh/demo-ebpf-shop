# 재고 서비스 (Ruby) — 상품·주문 서비스가 호출하고, 재고 수량은 Redis 에 둔다.
#
#   GET  /inventory/{productId}            재고 조회        (상품 서비스가 호출)
#   POST /inventory/{productId}/reserve    재고 차감 {qty}  (주문 서비스가 호출)
#
# Redis 는 외부 gem 없이 RESP 프로토콜을 직접 써서 평문으로 통신한다 (eBPF 가 Redis 명령을 볼 수 있게).
require 'json'
require 'logger'
require 'socket'
require 'webrick'

PORT = Integer(ENV.fetch('PORT', '8080'))
REDIS_HOST = ENV.fetch('REDIS_HOST', 'redis')
REDIS_PORT = Integer(ENV.fetch('REDIS_PORT', '6379'))
REDIS_PASSWORD = ENV.fetch('REDIS_PASSWORD', '')
INITIAL_STOCK = 1000

$stdout.sync = true
LOG = Logger.new($stdout)
LOG.formatter = proc { |sev, time, _, msg| "#{time.strftime('%Y-%m-%dT%H:%M:%S')} #{sev} inventory-service #{msg}\n" }

# 최소 Redis 클라이언트: 요청 스레드마다 연결 1개를 재사용하고, 끊기면 한 번 다시 연결한다.
module MiniRedis
  class Error < StandardError; end

  def self.call(*args)
    attempts = 0
    begin
      sock = connection
      sock.write("*#{args.size}\r\n" + args.map { |a| s = a.to_s; "$#{s.bytesize}\r\n#{s}\r\n" }.join)
      read_reply(sock)
    rescue IOError, SystemCallError => e
      reset
      attempts += 1
      retry if attempts < 2
      raise Error, "redis unavailable: #{e.message}"
    end
  end

  def self.connection
    Thread.current[:redis] ||= begin
      sock = Socket.tcp(REDIS_HOST, REDIS_PORT, connect_timeout: 2)
      Thread.current[:redis] = sock
      call('AUTH', REDIS_PASSWORD) unless REDIS_PASSWORD.empty?
      sock
    end
  end

  def self.reset
    Thread.current[:redis]&.close rescue nil
    Thread.current[:redis] = nil
  end

  def self.read_reply(sock)
    line = sock.gets("\r\n") or raise IOError, 'connection closed'
    type, rest = line[0], line[1..].chomp("\r\n")
    case type
    when '+' then rest
    when '-' then raise Error, rest
    when ':' then Integer(rest)
    when '$'
      len = Integer(rest)
      return nil if len.negative?
      data = sock.read(len + 2)
      data[0, len]
    when '*'
      Array.new(Integer(rest)) { read_reply(sock) }
    else
      raise Error, "unexpected reply: #{line.inspect}"
    end
  end
end

def stock_key(id) = "stock:#{id}"

def current_stock(id)
  value = MiniRedis.call('GET', stock_key(id))
  return Integer(value) if value
  MiniRedis.call('SET', stock_key(id), INITIAL_STOCK)
  INITIAL_STOCK
end

def json(res, status, body)
  res.status = status
  res['Content-Type'] = 'application/json'
  res.body = JSON.generate(body)
end

server = WEBrick::HTTPServer.new(
  Port: PORT, BindAddress: '0.0.0.0', DoNotReverseLookup: true,
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN), AccessLog: []
)

server.mount_proc('/health') { |_req, res| json(res, 200, status: 'UP') }

server.mount_proc('/inventory') do |req, res|
  req_id = req['X-Request-Id'] || '-'
  begin
    if req.request_method == 'GET' && (m = %r{\A/inventory/(\d+)\z}.match(req.path))
      id = m[1]
      json(res, 200, productId: Integer(id), stock: current_stock(id))
    elsif req.request_method == 'POST' && (m = %r{\A/inventory/(\d+)/reserve\z}.match(req.path))
      id = m[1]
      qty = [Integer(JSON.parse(req.body || '{}').fetch('qty', 1)), 1].max
      remaining = MiniRedis.call('DECRBY', stock_key(id), qty)
      if remaining.negative?
        # 데모가 멈추지 않도록 재고가 바닥나면 다시 채운다
        remaining = MiniRedis.call('INCRBY', stock_key(id), INITIAL_STOCK)
        LOG.info("restocked req=#{req_id} product=#{id} remaining=#{remaining}")
      end
      json(res, 200, productId: Integer(id), reserved: qty, remaining: remaining)
    else
      json(res, 404, error: 'not found')
    end
  rescue MiniRedis::Error => e
    LOG.warn("redis error req=#{req_id} #{req.request_method} #{req.path} err=#{e.message}")
    json(res, 503, error: 'inventory store unavailable')
  rescue JSON::ParserError, ArgumentError, KeyError
    json(res, 400, error: 'invalid request')
  end
end

trap('TERM') { server.shutdown }
LOG.info("listening on :#{PORT} redis=#{REDIS_HOST}:#{REDIS_PORT} auth=#{!REDIS_PASSWORD.empty?}")
server.start

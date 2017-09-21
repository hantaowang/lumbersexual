#!/usr/bin/env ruby

require "statsd-ruby"
require "securerandom"
require "uri"
require "logstash-logger"
require "timeout"
require "elasticsearch"
require "logger"

module Lumbersexual
  module Plugin
    class Latency

      def initialize(options, *args)
        @options = options
        @found = false
      end

      def perform
        if @options[:log]
          elastic = Elasticsearch::Client.new url: @options[:uri], logger: Logger.new(STDERR), log: @options[:log]
        else
          elastic = Elasticsearch::Client.new url: @options[:uri]
        end
        if @options[:udp]
          logger = LogStashLogger.new(type: :udp, host: 'logstash.q', port: 8125, buffer_max_interval: 0.25, buffer_max_items: 1000000)
        else
          logger = LogStashLogger.new(type: :tcp, host: 'logstash.q', port: 9125, buffer_max_interval: 0.25, buffer_max_items: 1000000)
        end
        if @options[:all]
          index_name = '_all'
        else
          index_name = Time.now.strftime('logstash-%Y.%m.%d')
        end

        @uuid = SecureRandom.uuid.delete('-')
        @sleep_count = 0
        @start_time = Time.now
        Timeout::timeout(@options[:timeout]) {
          logger.info @uuid
          puts "Logged #{@uuid} at #{Time.now} (#{Time.now.to_i})"
          until @found do
            result = elastic.search index: index_name, q: @uuid
            @found = true if result['hits']['total'] > 0
            @sleep_count += 1
            sleep @options[:interval]
          end
        }

        @end_time = Time.now
        puts "Found #{@uuid} at #{Time.now} (#{Time.now.to_i})"
        raise Interrupt
      end

      def report
        statsd = Statsd.new(@options[:statsdhost]).tap { |s| s.namespace = "lumbersexual.latency" } if @options[:statsdhost]

        if @found
          latency = @end_time - @start_time
          adjusted_latency = latency - (@options[:interval] * @sleep_count)
          puts "Measured Latency: #{latency}"
          puts "Interval Adjusted Latency: #{adjusted_latency}"
          statsd.gauge 'runs.failed', 0 if @options[:statsdhost]
          statsd.gauge 'runs.successful', 1 if @options[:statsdhost]
          statsd.gauge 'rtt.measured', latency if @options[:statsdhost] if @options[:statsdhost]
          statsd.gauge 'rtt.adjusted', adjusted_latency if @options[:statsdhost] if @options[:statsdhost]
        else
          statsd.gauge 'runs.failed', 1 if @options[:statsdhost]
          statsd.gauge 'runs.successful', 0 if @options[:statsdhost]
          puts "Latency: unknown, uuid #{@uuid} not found"
        end
      end
    end
  end
end

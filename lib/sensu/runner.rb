require File.join(File.dirname(__FILE__), 'base')
require File.join(File.dirname(__FILE__), 'socket')

module Sensu
  class Runner
    include Utilities

    attr_accessor :safe_mode

    def self.run(options={})
      runner = self.new(options)
      unless (ARGV.length > 0)
        print 'OK No arguments given, exit 0\n'
        exit 0
      end
      EM::run do
        runner.trap_signals
        runner.run_checks(arguments=ARGV)
        runner.stop
      end
    end

    def initialize(options={})
      base = Base.new(options)
      @logger = base.logger
      @settings = base.settings
      base.setup_process
      # @timers = Array.new
      @checks_in_progress = Array.new
    end

    def publish_result(check)
      payload = {
        #:client => @settings[:client][:name],
        :check => check
      }
      @logger.info('publishing check result', {
        :payload => payload
      })
 #    @transport.publish(:direct, 'results', MultiJson.dump(payload)) do |info|
 #      if info[:error]
 #        @logger.error('failed to publish check result', {
 #          :payload => payload,
 #          :error => info[:error].to_s
 #        })
 #      end
 #    end
    end

    def substitute_command_tokens(check)
      unmatched_tokens = Array.new
      substituted = check[:command].gsub(/:::([^:]*?):::/) do
        token, default = $1.to_s.split('|', -1)
        matched = token.split('.').inject(@settings[:client]) do |client, attribute|
          if client[attribute].nil?
            default.nil? ? break : default
          else
            client[attribute]
          end
        end
        if matched.nil?
          unmatched_tokens << token
        end
        matched
      end
      [substituted, unmatched_tokens]
    end

    def execute_check_command(check)
      @logger.debug('attempting to execute check command', {
        :check => check
      })
      unless @checks_in_progress.include?(check[:name])
        @checks_in_progress << check[:name]
        command, unmatched_tokens = substitute_command_tokens(check)
        if unmatched_tokens.empty?
          check[:executed] = Time.now.to_i
          execute = Proc.new do
            @logger.debug('executing check command', {
              :check => check
            })
            started = Time.now.to_f
            begin
              check[:output], check[:status] = IO.popen(command, 'r', check[:timeout])
            rescue => error
              check[:output] = 'Unexpected error: ' + error.to_s
              check[:status] = 2
            end
            check[:duration] = ('%.3f' % (Time.now.to_f - started)).to_f
            check
          end
          publish = Proc.new do |check|
            publish_result(check)
            @checks_in_progress.delete(check[:name])
          end
          EM.defer(execute, publish)
        else
          check[:output] = 'Unmatched command tokens: ' + unmatched_tokens.join(', ')
          check[:status] = 3
          check[:handle] = false
          publish_result(check)
          @checks_in_progress.delete(check[:name])
        end
      else
        @logger.warn('previous check command execution in progress', {
          :check => check
        })
      end
    end

    def run_checks(arguments)
      arguments.each do |check_file|
      @logger.warn("Checks for #{check_file}")
      check = {
        name: 'check_ssh',
        command: '/usr/local/sbin/nagios-plugins/check_tcp -H localhost -p 22'
      }
      execute_check_command(check)
    end

    def complete_checks_in_progress(&block)
      @logger.info('completing checks in progress', {
        :checks_in_progress => @checks_in_progress
      })
      retry_until_true do
        if @checks_in_progress.empty?
          block.call
          true
        end
      end
    end

    def stop
      @logger.warn('stopping')
      complete_checks_in_progress do
        @logger.warn('stopping reactor')
        EM::stop_event_loop
      end
    end

    def trap_signals
      @signals = Array.new
      STOP_SIGNALS.each do |signal|
        Signal.trap(signal) do
          @signals << signal
        end
      end
      EM::PeriodicTimer.new(1) do
        signal = @signals.shift
        if STOP_SIGNALS.include?(signal)
          @logger.warn('received signal', {
            :signal => signal
          })
          stop
        end
      end
    end

  end
end

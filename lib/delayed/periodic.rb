require 'rufus/scheduler'

module Delayed
class Periodic
  attr_reader :name, :cron

  def encode_with(coder)
    coder.scalar("!ruby/Delayed::Periodic", @name)
  end

  cattr_accessor :scheduled, :overrides
  self.scheduled = {}
  self.overrides = {}

  def self.add_overrides(overrides)
    overrides.each do |name, cron_line|
      # throws error if the line is malformed
      Rufus::Scheduler::CronLine.new(cron_line)
    end
    self.overrides.merge!(overrides)
  end

  STRAND = 'periodic scheduling'

  def self.cron(job_name, cron_line, job_args = {}, &block)
    raise ArgumentError, "job #{job_name} already scheduled!" if self.scheduled[job_name]
    cron_line = overrides[job_name] || cron_line
    self.scheduled[job_name] = self.new(job_name, cron_line, job_args, block)
  end

  def self.audit_queue
    # we used to queue up a job in a strand here, and perform the audit inside that job
    # however, now that we're using singletons for scheduling periodic jobs,
    # it's fine to just do the audit in-line here without risk of creating duplicates
    perform_audit!
  end

  # make sure all periodic jobs are scheduled for their next run in the job queue
  # this auditing should run on the strand
  def self.perform_audit!
    self.scheduled.each { |name, periodic| periodic.enqueue }
  end

  def initialize(name, cron_line, job_args, block)
    @name = name
    @cron = Rufus::Scheduler::CronLine.new(cron_line)
    @job_args = { :priority => Delayed::LOW_PRIORITY }.merge(job_args.symbolize_keys)
    @block = block
  end

  def enqueue
    Delayed::Job.enqueue(self, @job_args.merge(:max_attempts => 1, :run_at => @cron.next_time(Delayed::Periodic.now), :singleton => tag))
  end

  def perform
    @block.call()
  ensure
    begin
      enqueue
    rescue
      # double fail! the auditor will have to catch this.
      Rails.logger.error "Failure enqueueing periodic job! #{@name} #{$!.inspect}"
    end
  end

  def tag
    "periodic: #{@name}"
  end
  alias_method :display_name, :tag

  def self.now
    Time.zone.now
  end
end
end

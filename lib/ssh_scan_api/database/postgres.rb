require 'pg'
require 'time'

module SSHScan
  module DB
    class Postgres
      def initialize(client)
        @client = client
        initialize_prepared_statements
      end

      # Helps us create a SSHScan::DB::Postgres object with a hash
      def self.from_hash(opts)
        database = opts["name"] || "ssh_observatory"
        server = ENV['sshscan.database.host'] || opts["server"]
        port = opts["port"]
        username = opts["username"]
        password = opts["password"]

        client = PG.connect( host: server, port: port, user: username, password: password, dbname: database )
        return SSHScan::DB::Postgres.new(client)
      end

      def exec(sql)
        @client.exec(sql)
      end

      def initialize_prepared_statements
        @client.prepare("queue_scan", "insert into scans (target,port,state,uuid) values ($1, $2, $3, $4)")
        @client.prepare("batch_queue_scan", "insert into scans (target,port,state,uuid) values ($1, $2, $3, $4)")
        @client.prepare("run_scan", "update scans SET state = 'RUNNING' where uuid = $1")
        @client.prepare("complete_scan", "update scans SET (state,worker_id,scan) = ('COMPLETED',$1,$2) where uuid = $3")
        @client.prepare("error_scan", "update scans SET (state,worker_id,scan) = ('ERRORED',$1,$2) where uuid = $3")
        @client.prepare("find_scans", "select uuid from scans where target = $1 and port = $2")
        @client.prepare("get_scan", "select scan from scans where uuid = $1")
      end

      def queue_scan(target, port, uuid)
        @client.exec_prepared("queue_scan", [target, port, "QUEUED", uuid])
      end

      def batch_queue_scan(target, port, uuid)
        @client.exec_prepared("batch_queue_scan", [target, port, "BATCH_QUEUED", uuid])
      end

      def run_count
        results = @client.exec("SELECT COUNT(*) FROM scans WHERE state = 'RUNNING'").values
        return 0 if results.empty?
        return results.first.first.to_i
      end

      def queue_count
        results = @client.exec("SELECT COUNT(*) FROM scans WHERE state = 'QUEUED'").values
        return 0 if results.empty?
        return results.first.first.to_i
      end

      def batch_queue_count
        results = @client.exec("SELECT COUNT(*) FROM scans WHERE state = 'BATCH_QUEUED'").values
        return 0 if results.empty?
        return results.first.first.to_i
      end

      def error_count
        results = @client.exec("SELECT COUNT(*) FROM scans WHERE state = 'ERRORED'").values
        return 0 if results.empty?
        return results.first.first.to_i
      end

      def complete_count
        results = @client.exec("SELECT COUNT(*) FROM scans WHERE state = 'COMPLETE'").values
        return 0 if results.empty?
        return results.first.first.to_i
      end

      def total_count
        results = @client.exec("SELECT COUNT(*) FROM scans").values
        return 0 if results.empty?
        return results.first.first.to_i
      end

      # The age of the oldest record in QUEUED state, in seconds
      def queued_max_age
        max_age = 0
        times = @client.exec("select MIN(timestamp) from scans where state = 'QUEUED'").values.flatten

        return max_age if times.first.nil?
        max_age = Time.now - Time.parse(times.first)
        return max_age
      end

      def run_scan(uuid)
        @client.exec_prepared("run_scan", [uuid])
      end

      def get_scan(uuid)
        @client.exec_prepared("get_scan", [uuid])
        scan_result = @client.exec_prepared("get_scan", [uuid]).values.flatten.first

        if scan_result.nil?
          return {'error' => 'no matching uuid in datastore'}
        else
          return JSON.parse(@client.exec_prepared("get_scan", [uuid]).values.flatten.first)
        end
      end

      def complete_scan(uuid, worker_id, scan_result)
        @client.exec_prepared("complete_scan", [worker_id, scan_result, uuid])
      end

      def error_scan(uuid, worker_id, scan_result)
        @client.exec_prepared("error_scan", [worker_id, scan_result, uuid])
      end

      def auth_method_report
        auth_methods = [
          "publickey",
          "password"
        ]

        histogram = {}

        auth_methods.each do |auth_method|
         results = @client.exec("SELECT COUNT(*) from scans where scan->'auth_methods' @> '\"#{auth_method}\"'")
         histogram[auth_method ] = results.first.first[1].to_i
        end

        return histogram
      end

      def grade_report
        grades = ["A", "B", "C", "D", "F"]
        histogram = {}

        # Initilize as zero
        grades.each do |grade|
          histogram[grade] = 0
        end

        @client.exec("SELECT scan->'compliance'->>'grade' from scans").values.flatten.each do |grade|
          histogram[grade] += 1
        end

        return histogram
      end

      def next_scan_in_batch_queue
        results = @client.exec("SELECT uuid FROM scans WHERE state = 'BATCH_QUEUED' LIMIT 1").values
        return nil if results.empty?
        return results.first.first
      end

      def next_scan_in_queue
        results = @client.exec("SELECT uuid FROM scans WHERE state = 'QUEUED' LIMIT 1").values
        return nil if results.empty?
        return results.first.first
      end

      def find_recent_scans(target, port, test = false)

        # WORKAROUND: I had issues trying to type cast the interval properly with parameterized, so this is a safe workaround for the time being short of using unsafe SQL
        if test
          select_string = "select uuid from scans where target = $1 and port = $2 and timestamp > NOW() - INTERVAL '2 seconds'"
          return @client.exec_params(select_string, [target,port]).values.flatten
        else
          select_string = "select uuid from scans where target = $1 and port = $2 and timestamp > NOW() - INTERVAL '60 seconds'"
          return @client.exec_params(select_string, [target,port]).values.flatten
        end
      end

      def find_scans(target, port)
        @client.exec_prepared("find_scans", [target, port]).values.flatten
      end
    end
  end
end

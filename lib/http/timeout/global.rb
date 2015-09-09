require "timeout"

require "http/timeout/per_operation"

module HTTP
  module Timeout
    class Global < PerOperation
      attr_reader :time_left, :total_timeout

      def initialize(*args)
        super

        @time_left = connect_timeout + read_timeout + write_timeout
        @total_timeout = time_left
      end

      def connect(socket_class, host, port)
        reset_timer
        ::Timeout.timeout(time_left, TimeoutError) do
          @socket = socket_class.open(host, port)
        end

        log_time
      end

      def connect_ssl
        reset_timer

        begin
          socket.connect_nonblock
        rescue IO::WaitReadable
          IO.select([socket], nil, nil, time_left)
          log_time
          retry
        rescue IO::WaitWritable
          IO.select(nil, [socket], nil, time_left)
          log_time
          retry
        end
      end

      # Read from the socket
      def readpartial(size)
        reset_timer

        loop do
          begin
            result = read_nonblock(size)

            case result
            when :wait_readable
              wait_readable_or_timeout
            when :wait_writable
              wait_writable_or_timeout
            when NilClass
              return :eof
            else return result
            end
          rescue IO::WaitReadable
            wait_readable_or_timeout
          rescue IO::WaitWritable
            wait_writable_or_timeout
          end
        end
      rescue EOFError
        :eof
      end

      # Write to the socket
      def write(data)
        reset_timer

        loop do
          begin
            result = write_nonblock(data)

            case result
            when :wait_readable
              wait_readable_or_timeout
            when :wait_writable
              wait_writable_or_timeout
            else return result
            end
          rescue IO::WaitReadable
            wait_readable_or_timeout
          rescue IO::WaitWritable
            wait_writable_or_timeout
          end
        end
      rescue EOFError
        :eof
      end

      alias_method :<<, :write

      private

      if RUBY_VERSION < "2.1.0"

        def read_nonblock(size)
          @socket.read_nonblock(size)
        end

        def write_nonblock(data)
          @socket.write_nonblock(data)
        end

      else

        def read_nonblock(size)
          @socket.read_nonblock(size, :exception => false)
        end

        def write_nonblock(data)
          @socket.write_nonblock(data, :exception => false)
        end

      end

      # Wait for a socket to become readable
      def wait_readable_or_timeout
        timed_out = IO.select([@socket], nil, nil, time_left).nil?
        log_time
        return :timeout if timed_out
      end

      # Wait for a socket to become writable
      def wait_writable_or_timeout
        timed_out = IO.select(nil, [@socket], nil, time_left).nil?
        log_time
        return :timeout if timed_out
      end

      # Due to the run/retry nature of nonblocking I/O, it's easier to keep track of time
      # via method calls instead of a block to monitor.
      def reset_timer
        @started = Time.now
      end

      def log_time
        @time_left -= (Time.now - @started)
        if time_left <= 0
          fail TimeoutError, "Timed out after using the allocated #{total_timeout} seconds"
        end

        reset_timer
      end
    end
  end
end

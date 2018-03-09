defmodule FtpLogger do
    @moduledoc """
    Documentation for FtpLogger. There are 3 levels of logging
    0 -> No logging whatsoever
    1 -> Only log messages that are requests and responses to and from the client
    2 -> Log all messages
    """

    @desktop_logfile "lib/ftp_log.txt"
    require Logger
    use GenServer

    def start_link(_args = %{debug: debug, log_file_directory: dir, machine: machine, server_name: server_name}) do
        dir = String.trim_trailing(dir, "/")
        log_file = Enum.join([dir, "/ftp_log.txt"])
        name = Enum.join([server_name, "_ftp_logger"]) |> String.to_atom
        {:ok, _pid} = GenServer.start_link(__MODULE__, %{debug: debug, log_file: log_file, machine: machine, server_name: server_name}, name: name)
    end

    def init(state = %{log_file: log_file, machine: machine}) do
        Logger.info "Started Logger"
        case machine do ## check to see if we're on a Desktop
            :desktop -> 
                Logger.info("We're on a desktop. Every debug message will be logged with Logger.debug and also logged to #{inspect @desktop_logfile}")
                log_file_bak = String.trim_trailing(@desktop_logfile, ".txt")
                log_file_bak = Enum.join([log_file_bak, "1.txt"])
                case File.exists?(@desktop_logfile) do
                    true -> File.copy(@desktop_logfile, log_file_bak )
                    false -> :ok
                end
            other_machine -> 
                Logger.info("We're on an #{inspect other_machine}. Every debug message will be logged with Logger.info and also logged to #{inspect log_file}")
                log_file_bak = String.trim_trailing(log_file, ".txt")
                log_file_bak = Enum.join([log_file_bak, "1.txt"])
                case File.exists?(log_file) do
                    true -> File.copy(log_file, log_file_bak )
                    false -> :ok
                end
        end
        {:ok, state}
    end

    
    @doc """
    Handler to handle the log messages sent from FtpServer. These messages are prepended with the `server_name` before they get logged.
    """
    def handle_info({:ftp_server_log_message, message, priority}, state = %{debug: debug, log_file: log_file, machine: machine, server_name: server_name}) do
        message = Enum.join([server_name, " ", message])
        case debug do
            0 -> 
                :ok
            1 -> ## only log messages of priority `:comm`
                case priority do
                    :comm -> log_message(message, log_file, machine)
                    _ -> :ok
                end
            2 ->
                log_message(message, log_file, machine)
        end
        {:noreply, state}
    end


    @doc """
    Function to log messages. Both prints messages to console and writes messages to the log file

    NOT UNIT_TESTABLE
    """
    def log_message(message, log_file, machine) do
        case machine do
            :desktop -> 
                Logger.debug(message)
                message = String.trim_trailing(message, "\n")
                timestamp = DateTime.utc_now |> DateTime.to_string
                File.write(@desktop_logfile, Enum.join([timestamp, "  " , message, "\n"]), [:append])
            _other_machine -> 
                Logger.info(message)
                message = String.trim_trailing(message, "\n")
                timestamp = DateTime.utc_now |> DateTime.to_string
                File.write(log_file, Enum.join([timestamp, "  " , message, "\n"]), [:append])
        end
    end

end

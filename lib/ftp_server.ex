defmodule FtpServer do
    @moduledoc """
    Documentation for FtpServer. This GenServer is started by the FtpServerListener module.
    """

    ## The FTP return codes (Ones not in use have been commented out to remove warnings)
    @ftp_DATACONN            150
    #@ftp_OK                  200
    @ftp_NOOPOK              2000
    @ftp_TYPEOK              200
    @ftp_PORTOK              200
    @ftp_STRUOK              200
    @ftp_MODEOK              200
    #@ftp_ALLOOK              202
    @ftp_NOFEAT              211
    #@ftp_STATOK              211
    @ftp_STATFILE_OK         213
    @ftp_HELP                214
    @ftp_SYSTOK              215
    @ftp_GREET               220
    @ftp_GOODBYE             221
    @ftp_TRANSFEROK          226
    @ftp_ABORTOK             226
    @ftp_PASVOK              227
    #@ftp_EPRTOK              228
    #@ftp_EPSVOK              229
    @ftp_LOGINOK             230
    @ftp_CWDOK               250
    @ftp_RMDIROK             250
    @ftp_DELEOK              250
    #@ftp_RENAMEOK            250
    @ftp_PWDOK               257
    @ftp_MKDIROK             257
    @ftp_GIVEPWORD           331
    @ftp_RESTOK              350
    #@ftp_RNFROK              350
    #@ftp_TIMEOUT             421
    #@ftp_ABORT               421
    #@ftp_BADUSER_PASS        430
    #@ftp_BADSENDCONN         425
    #@ftp_BADSENDNET          426
    @ftp_TRANSFERABORTED     426
    #@ftp_BADSENDFILE         451
    #@ftp_BADCMD              500
    @ftp_OPTSFAIL            501
    #@ftp_COMMANDNOTIMPL      502
    #@ftp_NEEDUSER            503
    #@ftp_NEEDRNFR            503
    #@ftp_BADSTRU             504
    #@ftp_BADMODE             504
    @ftp_LOGINERR            530
    @ftp_FILEFAIL            550
    @ftp_NOPERM              550
    #@ftp_UPLOADFAIL          553

    @ftp_REPLYMYSELF           0
    @ftp_NORESPONSE            0
    @ftp_ERRRESPONSE          -1

    @special_content           1
    
    require Logger
    use GenServer

    def start_link(ref, socket, transport, _opts = [options]) do
        initial_state = options
            |> Map.put(:control_socket, socket)
            |> Map.put(:transport, transport)
        pid  = :proc_lib.spawn_link(__MODULE__, :init, [ref, socket, transport, initial_state])
        {:ok, pid}
    end

    def init(ref, socket, _transport, state) do
        start_listener(ref,socket, state)
        :gen_server.enter_loop(__MODULE__, [], [])
        {:ok, %{}}
    end
    
    ## Function present to remove warnings
    def init(_) do
        {:ok, []}
    end
    
    def start_listener(listener_pid, socket, state) do
        setup_dd(state)
        FtpData.set_server_pid(get(:ftp_data_pid), self())
        :ranch.accept_ack(listener_pid)
        set_socket_option(socket, :keepalive, true, false) ## we don't want control socket to close due to an inactivity timeout while a transfer is on-going on the data socket
        socket_status = Port.info(socket)
        logger_debug("Got Connection. Socket status: #{inspect socket_status}", :comm)
        send_message(@ftp_GREET, "Welcome to FTP Server", false)
        
        case :ranch_tcp.setopts(socket, [active: true]) do
            :ok -> logger_debug("Socket successfully set to active", :comm)
            {:error, reason} -> logger_debug("Socket not set to active. Reason #{reason}", :comm)
        end
        
        sucessful_authentication = auth(Map.get(state, :server_name))
        case sucessful_authentication do
            true ->
                logger_debug("Valid Login Credentials", :comm)
                send_message(@ftp_LOGINOK, "User Authenticated")
            false ->
                logger_debug("Invalid username or password\n", :comm)
                send_message(@ftp_LOGINERR, "Invalid username or password")
                close_socket(socket)
        end
    end


    @doc """
    Handler for when we receive log messages from FtpData. `message` is prepened with 
    a tag to tell the logger where exactly the message was sourced from.
    """
    def handle_info({:ftp_data_log_message, message}, state) do
        Enum.join([" [FTP_DATA]   ", message]) |> logger_debug
        {:noreply, state}
    end

    
    @doc """
    Handler for when we receive no-log messages from FtpData.
    """
    def handle_info({:from_ftp_data, msg},state) do
        ftp_data_pid = get(:ftp_data_pid)
        logger_debug "This is msg: #{inspect msg}"
        case msg do
            :socket_transfer_ok -> 
                send_message(@ftp_TRANSFEROK, "Transfer Complete")
            :socket_transfer_failed -> 
                was_aborted = FtpData.get_state(ftp_data_pid) |> Map.get(:aborted)
                case was_aborted do
                    true -> #:ok
                        send_message(@ftp_TRANSFERABORTED, "Connection closed; transfer aborted.")
                        send_message(@ftp_ABORTOK, "ABOR command successful")
                        reset_state()
                    false -> send_message(@ftp_FILEFAIL, "Transfer Failed")
                end
            :socket_close_ok -> 1#send_message(@ftp_TRANSFEROK, "Transfer Complete", socket)
            :socket_create_ok -> 2#send_message(@ftp_TRANSFEROK, "Transfer Complete", socket)
            _ -> :ok
        end
        {:noreply, state}
    end


    @doc """
    Handler for all TCP messages received on `socket`.
    """
    def handle_info({:tcp, socket, packet }, state) do
        control_socket = get(:control_socket)
        data_socket = get(:data_socket)
        cond do
            (socket == control_socket) -> 
                logger_debug "got command: #{packet}"
                handle_command(packet)
            (socket == data_socket ) ->
                logger_debug "got command for data socket: #{packet}"
            true ->
                logger_debug "got command from other socket #{socket}"
        end
        {:noreply, state}
    end

    
    @doc """
    Handler for when `socket` has been closed.
    """
    def handle_info({:tcp_closed, socket }, state) do
        socket_status = Port.info(socket)
        logger_debug "Socket #{inspect socket} closed. Actual Socket status: #{inspect socket_status} . Connection to client ended"
        {:noreply, state}
    end
    
    
    @doc """
    Handler for when this `GenServer` terminates
    """
    def terminate(reason, _state) do
        logger_debug "This is terminiate reason:\nSTART\n#{inspect reason}\nEND"
    end


    ## COMMAND HANDLERS

    @doc """
    Function to determine what action to take based on given command from the client
    """
    def handle_command(command) do
        logger_debug("FROM CLIENT: #{command}", :comm)
        socket = get(:control_socket)
        command = to_string(command)
        {code, response} =
        cond do
            String.contains?(command, "LIST") == true -> handle_list(command)
            String.contains?(command, "TYPE") == true -> handle_type(command)
            String.contains?(command, "STRU") == true -> handle_stru(command)
            String.contains?(command, "QUIT") == true -> handle_quit(command)
            String.contains?(command, "PORT") == true -> handle_port(command)
            String.contains?(command, "RETR") == true -> handle_retr(command)
            String.contains?(command, "STOR") == true -> handle_stor(command)
            String.contains?(command, "NOOP") == true -> handle_noop(command)
            String.contains?(command, "DELE") == true -> handle_dele(command)
            String.contains?(command, "MKD") == true -> handle_mkd(command)
            String.contains?(command, "RMD") == true -> handle_rmd(command)
            String.contains?(command, "SIZE") == true -> handle_size(command)
            String.contains?(command, "PASV") == true -> handle_pasv(command)
            String.contains?(command, "SYST") == true -> handle_syst(command)
            String.contains?(command, "FEAT") == true -> handle_feat(command)
            String.contains?(command, "PWD") == true -> handle_pwd(command)
            String.contains?(command, "CWD") == true -> handle_cwd(command)
            String.contains?(command, "REST") == true -> handle_rest(command)
            String.contains?(command, "MODE") == true -> handle_mode(command)
            String.contains?(command, "ABOR") == true -> handle_abor(command)
            String.contains?(command, "HELP") == true -> handle_help(command)
            String.contains?(command, "OPTS") == true -> handle_opts(command)
            #command_not_implemented(command) == true -> {@ftp_COMMANDNOTIMPL, "Command '#{inspect command}' not implemented on this server"}
            true -> {@ftp_ERRRESPONSE, "Junk Command"}
        end

        case code do
            @ftp_NORESPONSE -> :ok
            @ftp_ERRRESPONSE -> logger_debug "Don't know how to handle '#{inspect command}'"
            @ftp_GOODBYE ->
                send_message(code, response)
                close_socket(socket)
            _ -> send_message(code, response)
        end
    end


    @doc """
    Function to handle help commands. Still needs work for providing useful feedback
    """
    def handle_help(command) do
        case command do
            "HELP\r\n" ->
                {@ftp_HELP,"This is the help menu for the Elixir FTP Server"}
            _ ->
                "HELP " <> queried_command = command |> String.trim()
                {@ftp_HELP, "Currently, a help menu has not been implemented for '#{queried_command}'"}
        end
    end


    @doc """
    Function to handle opts commands. Still needs work for providing useful feedback
    """
    def handle_opts(_command) do
        {@ftp_OPTSFAIL, "OPTS is fully not supported yet"}
    end


    @doc """
    Function to handle dele command
    """
    def handle_dele(command) do
        "DELE " <> path = command |> String.trim()
        root_dir = get(:root_dir)
        current_client_working_directory = get(:client_cd)
        working_path = determine_path(root_dir, current_client_working_directory, path)
        path_exists = File.exists?(working_path)
        is_directory = File.dir?(working_path)
        have_read_access = allowed_to_read(working_path)
        have_write_access = allowed_to_write(working_path)

        cond do
            is_directory == true -> {@ftp_FILEFAIL, "Current path '#{path}' is a directory."}
            path_exists == false -> {@ftp_FILEFAIL, "Current directory '#{path}' does not exist."}
            have_read_access == false || have_write_access == false -> {@ftp_NOPERM, "You don't have permission to delete this file ('#{path}')."}
            true ->
                File.rm(working_path)
                {@ftp_DELEOK, "Successfully deleted file '#{path}'"}
        end
    end


    @doc """
    Function to handle rmd command
    """
    def handle_rmd(command) do
        command = String.trim_leading(command, "X") ## in the event we get an XRMD command
        "RMD " <> path = command |> String.trim()
        root_dir = get(:root_dir)
        current_client_working_directory = get(:client_cd)
        working_path = determine_path(root_dir, current_client_working_directory, path)
        path_exists = File.exists?(working_path)
        is_directory = File.dir?(working_path)
        have_read_access = allowed_to_read(working_path)
        have_write_access = allowed_to_write(working_path)

        cond do
            is_directory == false -> {@ftp_FILEFAIL, "Current path '#{path}' is not a directory."}
            path_exists == false -> {@ftp_FILEFAIL, "Current directory '#{path}' does not exist."}
            have_read_access == false || have_write_access == false -> {@ftp_NOPERM, "You don't have permission to delete this folder ('#{path}')."}
            true ->
                File.rmdir(working_path)
                {@ftp_RMDIROK, "Successfully deleted directory '#{path}'"}
        end
    end

    
    @doc """
    Function to handle mkd command
    """
    def handle_mkd(command) do
        command = String.trim_leading(command, "X") ## in the event we get an XMKD command
        "MKD " <> path = command |> String.trim()
        root_dir = get(:root_dir)
        current_client_working_directory = get(:client_cd)
        working_path = determine_path(root_dir, current_client_working_directory, path)
        path_exists = File.exists?(working_path)
        have_read_access = allowed_to_read(working_path)
        have_write_access = allowed_to_write(working_path)

        cond do
            path_exists == true -> {@ftp_FILEFAIL, "Current directory '#{path}' already exists."}
            have_read_access == false || have_write_access == false -> {@ftp_NOPERM, "You don't have permission to create this directory ('#{path}')."}
            true ->
                File.mkdir(working_path)
                {@ftp_MKDIROK, "Successfully created directory '#{path}'"}
        end
    end

    
    @doc """
    Function to handle noop command
    """
    def handle_noop(_command) do
        {@ftp_NOOPOK, "No Operation"}
    end

    
    @doc """
    Function to handle feat command
    """
    def handle_feat(_command) do
        {@ftp_NOFEAT, "no-features"}
    end

    
    @doc """
    Function to handle pasv command
    """
    def handle_pasv(_command) do
        p1 = :rand.uniform(230)
        p2 = :rand.uniform(230)
        port_number = p1*256 + p2
        ip = get(:control_ip)
        put(:data_ip, "127.0.0.1") ## update data socket info with new ip
        put(:data_port, port_number) ## update data socket info with new port_number
        {h1, h2, h3, h4} = ip
        pasv(ip, port_number)
        :timer.sleep(100) ## need to sleep to give ranch time to create socket
        send_message(@ftp_PASVOK, "Entering Passive Mode (#{inspect h1},#{inspect h2},#{inspect h3},#{inspect h4},#{inspect p1},#{inspect p2})")
        {@ftp_REPLYMYSELF, ""}
    end

    
    @doc """
    Function to handle abor command
    """
    def handle_abor(_command) do
        logger_debug "Handling abort.."
        abort()
        {@ftp_NORESPONSE, :ok}
    end

    
    @doc """
    Function to handle type command
    """
    def handle_type(command) do
        "TYPE " <> type = command |> String.trim()
        case type do
            "I" -> {@ftp_TYPEOK, "Image"}
            "A" -> {@ftp_TYPEOK, "ASCII"}
            "E" -> {@ftp_TYPEOK, "EBCDIC"}
            _ -> {@ftp_TYPEOK, "ASCII Non-print"}
        end
    end

    
    @doc """
    Function to handle rest command
    """
    def handle_rest(command) do
        "REST " <> offset = command |> String.trim()
        put(:file_offset, String.to_integer(offset)) ## update file_offset in dd
        {@ftp_RESTOK, "Rest Supported. Offset set to #{offset}"}
    end

    
    @doc """
    Function to handle syst command
    """
    def handle_syst(_command) do
        {@ftp_SYSTOK, "UNIX Type: L8"}
    end

    
    @doc """
    Function to handle stru command
    """
    def handle_stru(_command) do
        {@ftp_STRUOK, "FILE"}
    end

    
    @doc """
    Function to handle quit command
    """
    def handle_quit(_command) do
        {@ftp_GOODBYE, "Goodbye"}
    end

    
    @doc """
    Function to handle mode command
    """
    def handle_mode(command) do
        "MODE " <> mode = command |> String.trim()
        case mode do
            "C" -> {@ftp_MODEOK, "Compressed"}
            "B" -> {@ftp_MODEOK, "Block"}
            _ -> {@ftp_MODEOK, "Stream"}
        end
    end

    
    @doc """
    Function to handle port command
    """
    def handle_port(command) do
        "PORT " <> port_data = command |> String.trim()
        [ h1, h2, h3, h4, p1, p2] = String.split(port_data, ",")
        port_number = String.to_integer(p1)*256 + String.to_integer(p2)
        port = to_string(port_number)
        ip = Enum.join([h1, h2, h3, h4], ".")
        put(:data_ip, ip) ## update data socket info with new ip
        put(:data_port, port_number) ## update data socket info with new port_number
        {@ftp_PORTOK, "Client IP: #{ip}. Client Port: #{port}"}
    end

    
    @doc """
    Function to handle list command
    """
    def handle_list(command) do
        case command do
            "LIST\r\n" ->
                get(:server_cd) |> do_list()
                {@ftp_NORESPONSE, :ok}
            "LIST -a\r\n" ->
                get(:server_cd) |> do_list()
                {@ftp_NORESPONSE, :ok}
            _ -> ## assume it was 'LIST path'
                "LIST " <> path = command |> String.trim()
                root_dir = get(:root_dir)
                current_client_working_directory = get(:client_cd)
                working_path = determine_path(root_dir, current_client_working_directory, path)
        
                path_exists = File.exists?(working_path)
                have_read_access = allowed_to_read(working_path)
        
                cond do
                    path_exists == false -> {@ftp_FILEFAIL, "Current directory '#{path}' does not exist."}
                    have_read_access == false -> {@ftp_NOPERM, "You don't have permission to read from this directory ('#{path}')."}
                    true -> 
                        do_list(working_path)
                        {@ftp_NORESPONSE, :ok}
                end
        end
    end

    
    @doc """
    Function to handle size command
    """
    def handle_size(command) do
        "SIZE " <> path = command |> String.trim()
        root_dir = get(:root_dir)
        current_client_working_directory = get(:client_cd)
        working_path = determine_path(root_dir, current_client_working_directory, path)

        path_exists = File.exists?(working_path)
        is_directory = File.dir?(working_path)
        have_read_access = allowed_to_read(working_path)

        cond do
            is_directory == true -> {@ftp_FILEFAIL, "Current path '#{path}' is a directory."}
            path_exists == false -> {@ftp_FILEFAIL, "Current directory '#{path}' does not exist."}
            have_read_access == false -> {@ftp_NOPERM, "You don't have permission to read from this directory ('#{path}')."}
            true ->
                {:ok, info} = File.stat(working_path)
                file_size = Map.get(info, :size)
                {@ftp_STATFILE_OK, "#{file_size}"}
        end
    end

    
    @doc """
    Function to handle stor command
    """
    def handle_stor(command) do
        "STOR " <> path = command |> String.trim()

        root_dir = get(:root_dir)
        current_client_working_directory = get(:client_cd)
        ip = get(:data_ip)
        port = get(:data_port)

        working_path = determine_path(root_dir, current_client_working_directory, path)

        case allowed_to_stor(working_path) do
            true ->
                logger_debug "working_dir: #{working_path}"
                case File.exists?(working_path) do
                    true -> File.rm(working_path)
                    false -> :ok
                end
                send_message(@ftp_DATACONN, "Opening Data Socket to receive file...")
                ip = to_charlist(ip)
                create_socket(ip, port)
                stor(working_path)
                {@ftp_REPLYMYSELF, :ok}
            false ->
                {@ftp_NOPERM, "You don't have permission to write to this directory ('#{path}')."}
        end
    end

    
    @doc """
    Function to handle retr command
    """
    def handle_retr(command) do
        "RETR " <> path = command |> String.trim()
        
        root_dir = get(:root_dir)
        current_client_working_directory = get(:client_cd)
        ip = get(:data_ip)
        port = get(:data_port)
        offset = get(:file_offset)

        working_path = determine_path(root_dir, current_client_working_directory, path)

        path_exists = File.exists?(working_path)
        is_directory = File.dir?(working_path)
        have_read_access = allowed_to_read(working_path)

        cond do
            is_directory == true -> {@ftp_FILEFAIL, "Current path '#{path}' is a directory."}
            path_exists == false -> {@ftp_FILEFAIL, "Current directory '#{path}' does not exist."}
            have_read_access == false -> {@ftp_NOPERM, "You don't have permission to read from this directory ('#{path}')."}
            true ->
                send_message(@ftp_DATACONN, "Opening Data Socket for transfer of file #{path} from offset #{offset}...")
                ip = to_charlist(ip)
                create_socket(ip, port)
                retr(working_path, offset)
                {@ftp_REPLYMYSELF, :ok}
        end
    end

    
    @doc """
    Function to handle pwd command
    """
    def handle_pwd(_command) do
        logger_debug "Server CD: #{get(:server_cd)}"
        {@ftp_PWDOK, "\"#{get(:client_cd)}\""}
    end

    
    @doc """
    Function to handle cwd command
    """
    def handle_cwd(command) do
        "CWD " <> path = command |> String.trim()

        current_client_working_directory = get(:client_cd)
        root_directory = get(:root_dir)

        working_path = determine_path(root_directory, current_client_working_directory, path)
        logger_debug "This is working path on server: #{working_path}"
        new_client_working_directory = String.trim_leading(working_path, root_directory)
        new_client_working_directory = 
        case new_client_working_directory do
            "" -> "/"
            _ -> new_client_working_directory
        end
        
        path_exists = File.exists?(working_path)
        is_directory = File.dir?(working_path)
        have_read_access = allowed_to_read(working_path)

        cond do
            is_directory == false -> {@ftp_FILEFAIL, "Current path '#{new_client_working_directory}' is not a directory."}
            path_exists == false -> {@ftp_FILEFAIL, "Current directory '#{new_client_working_directory}' does not exist."}
            have_read_access == false -> {@ftp_NOPERM, "You don't have permission to read from this directory ('#{new_client_working_directory}')."}
            true ->
                put(:client_cd, new_client_working_directory) ## update client_cd in dd
                put(:server_cd, working_path) ## update server_cd in dd
                {@ftp_CWDOK, "Current directory changed to '#{new_client_working_directory}'"}
        end
    end


    ## HELPER FUNCTIONS

    
    @doc """
    Function to send any log messages to the FtpLogger module. A priority-based
    system is used:
    1. If `priority` equals `:all` (default) then all messages sent to this function will be logged
    2. If `priority` equals `:comm` then only messages that signify communication between the client and server will be logged
    """
    def logger_debug(message, priority \\ :all) do
        message = Enum.join([" [FTP]   ", message])
        pid = get(:ftp_logger_pid)
        Kernel.send(pid, {:ftp_server_log_message, message, priority})    
    end
    
    
    @doc """
    Function to send any messages to the client
    """
    def send_message(code, msg, socket_mode \\ true) do
        socket = get(:control_socket)
        
        message =
        case code do
            @special_content -> msg ## don't prepend the message with a code
            _ -> Enum.join([to_string(code), " " , msg, "\r\n"])
        end 

        ## temporarily set to false so we can send messages
        set_socket_option(socket, :active, false)
        
        case :ranch_tcp.send(socket, message) do
            :ok -> 
                message = String.trim_trailing(message, "\r\n") ## trim to make logging cleaner
                logger_debug("FROM SERVER #{message}", :comm)
                logger_debug("Message '#{message}' sent to client")
            {:error, reason} -> 
                logger_debug("Error sending message to Client: #{reason}", :comm) 
        end

        set_socket_option(socket, :active, socket_mode) ## reset to true (by default)
    end


    @doc """
    Function to perform the list command and sends the response to the FtpData GenServer for
    transmission to the client over the data socket
    """
    def do_list(working_path) do
        viewable = get(:limit_viewable_dirs) |> Map.get(:enabled)
        {:ok, files} = File.ls(working_path)
        files = 
        case viewable do
            true -> remove_hidden_folders(working_path, files)
            false -> files
        end
        file_info = get_info(working_path, files)
        file_info = Enum.join([file_info, "\r\n"])
        send_message(@ftp_DATACONN, "Opening Data Socket for transfer of ls command...")
        ip = get(:data_ip) |> to_charlist
        port = get(:data_port)
        create_socket(ip, port)
        list(file_info) ## do list command
    end


    @doc """
    Function to remove the hidden folders from the returned list from `File.ls` command,
    and only show the files specified in the `limit_viewable_dirs` struct.
    """
    def remove_hidden_folders(path, files) do
        root_dir = get(:root_dir)
        viewable_dirs = get(:limit_viewable_dirs) |> Map.get(:viewable_dirs)
        files = 
        for file <- files do
            Path.join([path, file]) ## prepend the root_dir to each file
        end
        viewable_dirs =
        for item <- viewable_dirs do
            file = elem(item, 0)
            Path.join([root_dir, file]) ## prepend the root_dir to each viewable path
        end

        list = 
        for viewable_dir <- viewable_dirs do
            for file <- files do 
                case (file == String.trim_leading(file, viewable_dir)) do
                    true -> nil
                    false -> String.trim_leading(file, path) |> String.trim_leading("/") ## remove the prepended `path` (and `\`) from the file so we can return the original file
                end
            end
        end

        List.flatten(list) |> Enum.filter(fn(x) -> x != nil end ) ## flatten list and remove the `nil` values from the list
    end
    
    
    @doc """
    Simple function to check if the user can view a file/folder. Function attempts to
    perform a `String.trim_leading` call on the `current_path`. If `current_path` is
    part of the `root_path`, the `String.trim_leading` call will be able to remove the
    `root_path` string from the `current_path` string. If not, it will simply return
    the original `current_path`
    """
    def allowed_to_read(current_path) do
        root_dir = get(:root_dir)
        %{enabled: enabled, viewable_dirs: viewable_dirs } = get(:limit_viewable_dirs)
        cond do
            ( is_within_directory(root_dir, current_path) == false ) -> false
            ( enabled == true && (is_within_viewable_dirs(viewable_dirs, current_path) == false) && current_path != root_dir ) -> false
            true -> true
        end
    end

    
    @doc """
    Function to check if `current_path` is within any of the directories specified
    in the `viewable_dirs` list. 
    """
    def is_within_viewable_dirs(viewable_dirs, current_path) do
        root_dir = get(:root_dir)
        list = 
        for item <- viewable_dirs do
            dir = elem(item, 0)
            dir = Path.join([root_dir, dir])
            is_within_directory(dir, current_path)
        end
        |> Enum.filter(fn(x) -> x == true end ) ## filter out all of the `true` values in the list

        case list do
            [] -> false ## if no `true` values were returned (i.e. empty list), then `current_path` is not readable
            _ -> true
        end
    end


    @doc """
    Function to check if `current_path` is within any of the directories specified
    in the `viewable_dirs` list. Only checks directories with `:rw` permissions
    """
    def is_within_writeable_dirs(viewable_dirs, current_path) do
        root_dir = get(:root_dir)
        list = 
        for {dir, access} <- viewable_dirs do
            case access do 
                :rw ->
                    dir = Path.join([root_dir, dir])
                    is_within_directory(dir, current_path)
                :ro ->
                    false
            end
            
        end
        |> Enum.filter(fn(x) -> x == true end ) ## filter out all of the `true` values in the list

        case list do
            [] -> false ## if no `true` values were returned (i.e. empty list), then `current_path` is not writeable
            _ -> true
        end
    end


    @doc """
    Function to check if `current_path` is within `root_dir`
    """
    def is_within_directory(root_dir, current_path) do
        case (current_path == root_dir) do
            true -> 
                true
            false ->
                case (current_path == String.trim_leading(current_path, root_dir)) do
                    true -> false
                    false -> true
                end
        end
    end


    @doc """
    Function used to determine if a user is allowed to write to the `current_path`
    """
    def allowed_to_write(current_path) do
        root_dir = get(:root_dir)
        %{enabled: enabled, viewable_dirs: viewable_dirs } = get(:limit_viewable_dirs)
        cond do
            ( is_within_directory(root_dir, current_path) == false ) -> false
            ( enabled == true && is_within_writeable_dirs(viewable_dirs, current_path) == false ) -> false
            ( is_read_only_dir(current_path) == true ) -> false
            true -> true
        end
    end


    @doc """
    Function used to determine if a user is allowed to write a file in the the `file_path`
    """
    def allowed_to_stor(file_path) do
        file_name = String.split(file_path, "/") |> List.last
        parent_folder = String.trim_trailing(file_path, file_name)
        allowed_to_write(parent_folder)
    end


    @doc """
    Function to check is `path` is part of the machines own read-only  filesystem
    """
    def is_read_only_dir(path) do
        {:ok, info} = File.stat(path)
        case Map.get(info, :access) do
            :read -> true
            :none -> true
            _ -> false
        end
    end

    
    @doc """
    Iterator for getting all of the file info for each `file` in `files`, and then
    returns them as a single string
    """
    def get_info(cd,files) do
        list = for file <- files, do: Enum.join([cd, "/", file]) |> format_file_info
        Enum.join(list, "\r\n")
    end


    @doc """
    Function to format all of the file info into a single string, in a UNIX-like format
    """
    def format_file_info(file) do
        root_dir = get(:root_dir)
        name = String.trim_leading(file, root_dir) |> String.split("/") |> List.last
        logger_debug "getting info for #{file}"
        {:ok, info} = File.stat(file)
        size = Map.get(info, :size)
        {{_y, m, d}, {h, min, _s}} = Map.get(info, :mtime)
        time = Enum.join([h, min], ":")
        m = format_month(m)
        timestamp = Enum.join([m, d, time], " ")
        links = Map.get(info, :links)
        uid = Map.get(info, :uid)
        gid = Map.get(info, :gid)
        type = Map.get(info, :type)
        access = Map.get(info, :access)
        permissions = format_permissions(type, access)
        Enum.join([permissions, links, uid, gid, size, timestamp, name], " ")
    end


    @doc """
    Function to the permissions in a UNIX-like format
    """
    def format_permissions(type, access) do
        directory =
        case type do
            :directory -> "d"
            _ -> "-"
        end
        permissions =
        case access do
            :read -> "r--"
            :write -> "w--"
            :read_write -> "rw-"
            :none -> "---"
        end
        Enum.join([directory, permissions, permissions, permissions])
    end


    @doc """
    Function to format the month, given `month` passed in as an integer
    """
    def format_month(month) do
        cond do
            month == 1 -> "Jan"
            month == 2 -> "Feb"
            month == 3 -> "Mar"
            month == 4 -> "Apr"
            month == 5 -> "May"
            month == 6 -> "Jun"
            month == 7 -> "Jul"
            month == 8 -> "Aug"
            month == 9 -> "Sep"
            month == 10 -> "Oct"
            month == 11 -> "Nov"
            month == 12 -> "Dec"
            true -> "Err"
        end
    end


    @doc """
    Function to perform the authenication at the beginning of a connection
    """
    def auth(server_name) do
        data = receive do
            {:tcp, _socket, data} -> data
          end
        logger_debug "Username Given: #{inspect data}"
        "USER " <> username = to_string(data) |> String.trim()

        send_message(@ftp_GIVEPWORD,"Enter Password")
        
        data = receive do
            {:tcp, _socket, data} -> data
          end
        logger_debug "Password Given: #{inspect data}"
        "PASS " <> password = to_string(data) |> String.trim()

        ftp_auth_name = Enum.join([server_name, "_ftp_auth"]) |> String.to_atom()
        FtpAuth.authenticate(ftp_auth_name, username, password)
    end


    @doc """
    Function to determine if `path` is absolute
    """
    def is_absolute_path(path) do
        case ( path == String.trim_leading(path, "/") ) do
            true -> false
            false -> true
        end
    end


    @doc """
    Function to determine the path as it is on the filesystem, given the `root_directory` on the ftp server, `current_directory` 
    (as the client sees it) and the `path` provided by the client.
    """
    def determine_path(root_directory, current_directory, path) do
        ## check if path given is an absolute path
        new_path = 
        case is_absolute_path(path) do
            true -> String.trim_leading(path, "/") |> Path.expand(root_directory)
            false -> String.trim_leading(path, "/") |> Path.expand(current_directory) |> String.trim_leading("/") |> Path.expand(root_directory)
        end
        logger_debug "This is the path we were given: '#{path}'. This is current_directory: '#{current_directory}'. This is root_directory: '#{root_directory}'. Determined that this is the current path: '#{new_path}'"
        new_path
    end


    @doc """
    Function to close the control socket
    """
    def close_socket(socket) do
        case (socket == nil) do
            true -> logger_debug "Socket #{inspect socket} already closed."
            false ->
                case :gen_tcp.shutdown(socket, :read_write) do
                    :ok -> logger_debug "Socket #{inspect socket} successfully closed."
                    {:error, :closed} -> logger_debug "Socket #{inspect socket} already closed."
                    {:error, other_reason} -> logger_debug "Error while attempting to close socket #{inspect socket}. Reason: #{other_reason}."
                end
        end
    end


    @doc """
    Function to get from the Process data dictionary (dd)
    """
    def put(key, value) do
        new_map = Process.get(:data_dictionary) |> Map.put(key, value)
        Process.put(:data_dictionary, new_map)
    end


    @doc """
    Function to put in the Process data dictionary (dd)
    """
    def get(key \\ nil) do
        case key do
          nil -> Process.get(:data_dictionary)
          _ -> Process.get(:data_dictionary) |> Map.get(key)
        end
    end


    @doc """
    Function to quicky add the initial state to the Process data dictionary (dd)
    """
    def setup_dd(args) do
        initial_state = 
        %{
            root_dir: Map.get(args, :root_dir),
            ftp_data_pid: Map.get(args, :ftp_data_pid),
            control_socket: Map.get(args, :control_socket),
            data_socket: nil,
            username: Map.get(args, :username), 
            password: Map.get(args, :password), 
            control_ip: Map.get(args, :ip), 
            control_port: Map.get(args, :port),
            data_ip: nil,
            data_port: nil,
            client_cd: "/",
            server_cd: Map.get(args, :root_dir),
            file_offset: 0,
            transfer_type: nil,
            restart_time: Map.get(args, :restart_time),
            debug: Map.get(args, :debug),
            timeout: Map.get(args, :timeout),
            in_pasv_mode: false,
            aborted: false,
            listener_ref: Map.get(args, :listener_ref),
            ftp_logger_pid: Map.get(args, :ftp_logger_pid),
            server_name: Map.get(args, :server_name),
            limit_viewable_dirs: Map.get(args, :limit_viewable_dirs)
        }
        Process.put(:data_dictionary, initial_state)
        logger_debug "DD Set Up #{inspect get()}..."
    end


    @doc """
    Function to set socket options. See http://erlang.org/doc/man/inet.html#setopts-2
    for various options that can be set
    """
    def set_socket_option(socket, option, value, quiet_mode \\ true) do
        before = :inet.getopts(socket, [option])
        case :ranch_tcp.setopts(socket, [{option, value}]) do
            :ok ->
                after1 = :inet.getopts(socket, [option])
                case quiet_mode do
                    true -> :ok
                    false -> logger_debug "Set value of #{inspect option} before: #{inspect before} | after: #{inspect after1}"
                end
                
            {:error, reason} -> 
                case quiet_mode do
                    true -> :ok
                    false -> logger_debug "#{inspect option}  not set. Reason #{reason}"
                end
        end  
    end

    ## Functions for messaging FtpData by sending kernel messages.
    ## These are necessary because sometimes the FtpPasvSocket GenServer
    ## does not start in time before commands get sent to it. Sending messages
    ## to the handle_info callbacks allows us to call those functions in the FtpData
    ## on themselves easily in the event that the FtpPassiveSocket GenServer is not
    ## fully ready for use

    def list(file_info) do
        get(:ftp_data_pid) |> Kernel.send({:list, file_info})
    end

    def create_socket(ip, port) do
        get(:ftp_data_pid) |> Kernel.send({:create_socket, ip, port})
    end

    def stor(working_path) do
        get(:ftp_data_pid) |> Kernel.send({:stor, working_path})
    end

    def retr(working_path, offset) do
        get(:ftp_data_pid) |> Kernel.send({:retr, working_path, offset})
    end

    def abort() do
        get(:ftp_data_pid) |> Kernel.send({:close_data_socket, :abort})
    end

    def reset_state() do
        get(:ftp_data_pid) |> Kernel.send(:reset_state)
    end

    def pasv(ip, port) do
        get(:ftp_data_pid) |> Kernel.send({:pasv, ip, port})
    end
end

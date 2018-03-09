defmodule FtpPasvSocket do
    @moduledoc """
    Documentation for FtpActiveSocket
    """
    require Logger
    use GenServer

    @chunk_size 2048 ## Chunk size (in bytes) to send at a time
    
    
    def start_link(ref, socket, transport, _opts = [%{ftp_data_pid: ftp_data_pid, aborted: aborted, socket: _initial_socket, server_name: server_name}]) do
        new_server_name = Enum.join([server_name, "_", "ftp_pasv_socket"])
        initial_state = %{ftp_data_pid: ftp_data_pid, aborted: aborted, socket: socket, server_name: new_server_name}
        pid  = :proc_lib.spawn_link(__MODULE__, :init, [ref, socket, transport, initial_state])
        {:ok, pid}
    end

    
    def init(ref, socket, _transport, state) do
        start_listener(ref,socket, state)
        :gen_server.enter_loop(__MODULE__, [], state)
        {:ok, %{}}
    end  

    ## Function present to remove warnings
    def init(_) do
        {:ok, []}
    end
    
    def start_listener(ref, _socket, state) do
        ftp_data_pid = Map.get(state, :ftp_data_pid)
        Process.put(:ftp_data_pid, ftp_data_pid)
        logger_debug "Ftp Passive Starting..."
        message_ftp_data({:ftp_pasv_socket_pid, self()}) ## tell parent my pid
        :ranch.accept_ack(ref)
        logger_debug "Got Connection on Passive socket"
    end

    
    def retr(pid, file, offset) do
        GenServer.cast pid, {:retr, file, offset}
    end
  
    
    def close_data_socket(pid, reason) do
        GenServer.call pid, {:close_data_socket, reason}
    end
  
    
    def list(pid, file_info) do
        GenServer.cast pid, {:list, file_info}
    end

    
    def stor(pid, to_path) do
        GenServer.cast pid, {:stor, to_path}
    end
    
    
    @doc """
    Handler used when the FTP Server wants to close the passive data socket from receiving an abort command. Technically does not close
    the socket, as it expects that the socket will be closed and handled by whatever function is using the socket at the time
    of the abort. This just updates the `aborted` key of the `state`.
    """
    def handle_call({:close_data_socket, :abort}, _from, state) do
        logger_debug "Closing Data Socket (due to abort command)..."
        {:reply, state, %{state | aborted: true}}
    end

    
    @doc """
    Handler that is called when a client runs the "ls" command. This handler actually sends the data back to the client when in "active" mode has
    been selected
    """
    def handle_cast({:list, file_info}, state = %{socket: socket}) do
        logger_debug "Sending result from LIST command... -- #{inspect state}"
        :gen_tcp.send(socket, file_info)
        logger_debug "Result from LIST command sent. Sent #{inspect file_info}"
        message_ftp_data(:socket_transfer_ok)
        message_ftp_data(:close_pasv_socket)
        {:noreply, state}
    end

    
    @doc """
    Handler that is called when a client runs the "put" command. This handler is the top level when a client wants to upload a file in "passive" mode
    """
    def handle_cast({:stor, to_path}, state = %{socket: socket}) do
        logger_debug "Receiving file..."
        Kernel.send(self(), {:recv, socket, to_path})
        {:noreply, state}
    end

    
    @doc """
    Handler that is called when a client runs the "get" command. This handler is the top level when sending a file to the client in "passive" mode
    """
    def handle_cast({:retr, file, new_offset}, state = %{socket: socket}) do
        file_info = transfer_info(file, @chunk_size, new_offset)
        logger_debug "Sending file (#{inspect file_info})..."
        send_file(socket, file, file_info, new_offset, @chunk_size, 1)
        {:noreply, state}
    end


    @doc """
    Handler that is used with the `send` function to act like a "while loop" in other programming languages. Everytime the `send` function
    is finished executing, it makes a call to this handler, which in turn will call the send function again, provided the data transfer
    has not been aborted.
    """
    def handle_info({:send, {socket, file, file_info, new_offset, bytes, transmission_number}}, state = %{aborted: aborted}) do
        case aborted do
          false ->
            send_file(socket, file, file_info, new_offset, bytes, transmission_number)
          true ->
            logger_debug "Aborting this transfer"
            message_ftp_data(:socket_transfer_failed)
        end
        {:noreply, state}
    end

    
    @doc """
    Handler that provides looping with the `receive_file` function
    """
    def handle_info({:recv, socket, to_path}, state) do
        receive_file(socket, to_path)
        {:noreply, state}
    end

    
    @doc """
    Function that analyses file `file`, and returns the file's size, the number of transmissions needed to transmit this file based on the `offset` 
    and `chunk_size`, and also the exact size of the last transmission of the last chunk (where `last_transmission_size` <= `chunk_size`).

    Examples
    
        iex> File.write("testfile1.txt", "abcdefghijklmnopqrstuvwxyz")
        iex> return_val = FtpPasvSocket.transfer_info("testfile1.txt", 3, 0, true)
        iex> File.rm("testfile1.txt")
        iex> return_val
        %{file_size: 26, last_transmission_size: 2, transmissions: 9}
    """
    def transfer_info(file, chunk_size, offset, test_mode \\ false) do
    {:ok, info} = File.stat(file)
    file_size = Map.get(info, :size) - offset
    no_transmissions_needed = Integer.floor_div((file_size), chunk_size) + 1
    last_transmission_size = file_size - (no_transmissions_needed-1)*chunk_size
    case test_mode do
        true -> :ok
        false -> logger_debug "For filesize #{inspect file_size}  number of transmissions real = #{inspect no_transmissions_needed}   last_transmission_size = #{last_transmission_size}"
    end
    %{file_size: file_size, transmissions: no_transmissions_needed, last_transmission_size: last_transmission_size}
    end

    
    @doc """
    Function to get the transfer status. Will return a string with the percentage of the file that has been transferred or a `:no_status` item
    if the percentage somehow cannot be computted. Compares the `current_transmission_number` against the total `no_transmissions`.

    Examples
        
        iex> FtpPasvSocket.get_transfer_status(5, 10)
        "50%"
        iex> FtpPasvSocket.get_transfer_status(8, 10)
        "80%"
    """
    def get_transfer_status(t, no_transmissions) do
        t1 = no_transmissions*(1/10) |> Float.floor
        t2 = no_transmissions*(2/10) |> Float.floor
        t3 = no_transmissions*(3/10) |> Float.floor
        t4 = no_transmissions*(4/10) |> Float.floor
        t5 = no_transmissions*(5/10) |> Float.floor
        t6 = no_transmissions*(6/10) |> Float.floor
        t7 = no_transmissions*(7/10) |> Float.floor
        t8 = no_transmissions*(8/10) |> Float.floor
        t9 = no_transmissions*(9/10) |> Float.floor
        
        cond do
            t == t1 -> "10%"
            t == t2 -> "20%"
            t == t3 -> "30%"
            t == t4 -> "40%"
            t == t5 -> "50%"
            t == t6 -> "60%"
            t == t7 -> "70%"
            t == t8 -> "80%"
            t == t9 -> "90%"
            true -> :no_status
        end
    end

    
    @doc """
    Function used to send file to a client. The bytes are not transferred here. They are transferred in `send_chunk`, but this function tells
    `send_chunk` which bytes to send.

    NOT UNIT-TESTABLE
    """
    def send_file(socket, file, file_info, offset, bytes, transmission_number) do
        no_transmissions = Map.get(file_info,:transmissions)
        status = get_transfer_status(transmission_number, no_transmissions)
        cond do
            transmission_number == (no_transmissions+1) ->
            logger_debug "File Sent"
            message_ftp_data(:socket_transfer_ok)
            message_ftp_data(:close_pasv_socket)
            transmission_number == no_transmissions -> 
            bytes = Map.get(file_info,:last_transmission_size)
            send_chunk(socket, file, offset, bytes)
            new_offset = offset+bytes
            transmission_number = transmission_number+1
            Kernel.send(self(), {:send, {socket, file, file_info, new_offset, bytes, transmission_number}}) 
            true ->
            send_chunk(socket, file, offset, bytes)
            case status do
                :no_status -> :ok
                _ -> logger_debug "File Transfer status #{status}"
            end
            new_offset = offset+bytes
            transmission_number = transmission_number+1
            Kernel.send(self(), {:send, {socket, file, file_info, new_offset, bytes, transmission_number}}) 
        end    
    end
      
    
    @doc """
    Function to send `bytes` number of bytes of file `file` from offset `offset ` over socket `socket`. Will return `:chunk_sent` upon a successful
    transfer, and `:chunk_not_sent` upon an unsuccessful transfer.

    NOT UNIT-TESTABLE
    """
    def send_chunk(socket, file, offset, bytes) do
        #logger_debug "trying to send chunk for #{inspect bytes} from offset #{offset}"
        case :ranch_tcp.sendfile(socket, file, offset, bytes) do
            {:ok, _exit_code} -> :chunk_sent
            {:error, _reason} -> :chunk_not_sent
        end
    end


    @doc """
    Function used to message the FtpData `GenServer` (this GenServer's parent).

    NOT UNIT_TESTABLE
    """
    def message_ftp_data(message) do
        pid = Process.get(:ftp_data_pid)
        Kernel.send(pid, {:from_pasv_socket, message})
    end

    
    @doc """
    Function used to send log messages to the FtpLogger `GenServer`. Messages are not send directly to it, but instead follow this path:
    FtpPasvSocket -> FtpData -> FtpServer -> FtpLogger

    This ensures that messages are being logged in order.

    NOT UNIT_TESTABLE
    """
    def logger_debug(message) do
        pid = Process.get(:ftp_data_pid)
        Kernel.send(pid, {:ftp_pasv_log_message, message})
    end

    @doc """
    Function used to receive a file from an FTP client.

    NOT UNIT_TESTABLE
    """
    def receive_file(socket, to_path) do
        case :ranch_tcp.recv(socket, 0, 10000) do
            {:ok, new_file} ->
                File.write(to_path, new_file, [:append])
                receive_file(socket, to_path)
                #Kernel.send(self(), {:recv, socket, to_path})
            {:error, :closed} ->
                logger_debug "Finished receiving file."
                {:ok, info} = File.stat(to_path)
                file_size = Map.get(info, :size)
                logger_debug("This is size: #{inspect file_size}")
                logger_debug "File received."
                message_ftp_data(:socket_transfer_ok)
                message_ftp_data(:close_pasv_socket)
            {:error, other_reason} ->
                logger_debug "Error receiving file: #{other_reason}"
        end
    end

end
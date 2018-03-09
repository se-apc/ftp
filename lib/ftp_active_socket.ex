defmodule FtpActiveSocket do
  @moduledoc """
  Documentation for FtpActiveSocket. This module starts a GenServer that is used to handle all ftp transfers between the server
  and client when an "active" data socket is used.
  """
  require Logger
  use GenServer

  @chunk_size 2048
  
  def start_link(_state = %{ftp_data_pid: ftp_data_pid, aborted: aborted, server_name: server_name}) do
      name = Enum.join([server_name, "_ftp_active_socket"]) |> String.to_atom
      initial_state = %{ socket: nil, ftp_data_pid: ftp_data_pid, aborted: aborted, server_name: name}
      GenServer.start_link(__MODULE__, initial_state, name: name)
  end
  
  
  def init(state = %{ftp_data_pid: ftp_data_pid}) do
      Process.put(:ftp_data_pid, ftp_data_pid)
      {:ok, state}
  end

  
  def reset_state(pid) do
    GenServer.cast pid, :reset_state
  end

  
  def retr(pid, file, offset) do
    GenServer.cast pid, {:retr, file, offset}
  end

  
  def stor(pid, to_path) do
    GenServer.cast pid, {:stor, to_path}
  end

  
  def list(pid, path) do
    GenServer.cast pid, {:list, path}
  end

  
  def close_data_socket(pid) do
    GenServer.call pid, {:close_data_socket}
  end

  
  def close_data_socket(pid, reason) do
    GenServer.call pid, {:close_data_socket, reason}
  end

  
  def create_socket(pid, new_ip, new_port) do
    GenServer.call pid, {:create_socket, new_ip, new_port}
  end


  @doc """
  Handler to reset to the Active Server socket state to the default state
  """
  def handle_cast(:reset_state, _state=%{ftp_data_pid: ftp_data_pid, server_name: server_name}) do
    logger_debug "Resetting Active Socket Server State"
    {:noreply, %{socket: nil, ftp_data_pid: ftp_data_pid, aborted: false, server_name: server_name}}
  end


  @doc """
  Handler that is called when a client runs the "get" command. This handler is the top level when sending a file to the client in "active" mode
  """
  def handle_cast({:retr, file, new_offset} , state=%{socket: socket}) do
    file_info = transfer_info(file, @chunk_size, new_offset)
    logger_debug "Sending file (#{inspect file_info})..."
    send_file(socket, file, file_info, new_offset, @chunk_size, 1)
    {:noreply, state}
  end


  @doc """
  Handler that is called when a client runs the "put" command. This handler is the top level when a client wants to upload a file in "active" mode
  """
  def handle_cast({:stor, to_path} , state = %{socket: socket}) do
    logger_debug "Receiving file..."
    Kernel.send(self(), {:recv, socket, to_path})
    {:noreply, state}
  end


  @doc """
  Handler that is called when a client runs the "ls" command. This handler actually sends the data back to the client when in "active" mode has
  been selected
  """
  def handle_cast({:list, file_info} , state=%{socket: socket}) do
    logger_debug "Sending result from LIST command..."
    :gen_tcp.send(socket, file_info)
    logger_debug "Result from LIST command sent. Sent #{inspect file_info}"
    message_ftp_data(:socket_transfer_ok)
    new_socket_state = close_socket(socket)
    {:noreply, %{state | socket: new_socket_state}}
  end


  @doc """
  Handler used when the FTP Server wants to close the active data socket. Calls the `close_socket` function. Handles all cases of closing a
  socket except an abort command. This is handled with the `{close_data_socet, :abort}` handler.
  """
  def handle_call(:close_data_socket, _from, state=%{socket: socket}) do
    logger_debug "Closing Data Socket..."
    new_socket_state = close_socket(socket)
    message_ftp_data(:socket_close_ok)
    {:reply, state, %{state | socket: new_socket_state}}
  end


  @doc """
  Handler used when the FTP Server wants to close the active data socket from receiving an abort command. Calls the `close_socket` function.
  """
  def handle_call({:close_data_socket, :abort}, _from, state) do
    logger_debug "Closing Data Socket (due to abort command)..."
    #new_socket_state = close_socket(socket) ## there is acutally no need to close the data socket here as the socket will already have been closed by whatever function was in use at the time of the abort
    {:reply, state, %{state | aborted: true}}
  end

  
  @doc """
  Handler to create the active socket. Does so using `:ranch_tcp.connect`
  """
  def handle_call({:create_socket, new_ip, new_port}, _from, state) do
    logger_debug "Connecting  to #{inspect new_ip}:#{inspect new_port}"
    {:ok, socket} = :ranch_tcp.connect(new_ip, new_port ,[active: false, mode: :binary, packet: :raw, exit_on_close: true, linger: {true, 100}]) 
    socket_status = Port.info(socket)
    logger_debug "This is new data_socket #{inspect socket} info: #{inspect socket_status}"
    message_ftp_data(:socket_create_ok)
    {:reply, state, %{state | socket: socket}}
  end


  @doc """
  Handler for handling messages received from the FtpData module (this modules parent)
  """
  def handle_info({:from_ftp_data, _message}, state) do
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
  Handler for setting the socket state after PUT command has finished
  """
  def handle_info({:recv_finished, new_socket}, state) do
    {:noreply, %{state | socket: new_socket}}
  end

  
  @doc """
  Handler that is used with the `send` function to act like a "while loop" in other programming languages. Everytime the `send` function
  is finished executing, it makes a call to this handler, which in turn will call the send function again, provided the data transfer
  has not been aborted.
  """
  def handle_info({:send, {socket, file, file_info, new_offset, bytes, transmission_number}}, state = %{aborted: aborted}) do
    new_socket =
    case aborted do
      false ->
        send_file(socket, file, file_info, new_offset, bytes, transmission_number)
        socket
      true ->
        logger_debug "Aborting this transfer"
        new_socket = close_socket(socket)
        message_ftp_data(:socket_transfer_failed)
        new_socket
    end
    {:noreply, %{state | socket: new_socket}}
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
        close_socket(socket)
        :whole_file_sent
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
  Function that analyses file `file`, and returns the file's size, the number of transmissions needed to transmit this file based on the `offset` 
  and `chunk_size`, and also the exact size of the last transmission of the last chunk (where `last_transmission_size` <= `chunk_size`).

  Examples
    
    iex> File.write("testfile1.txt", "abcdefghijklmnopqrstuvwxyz")
    iex> return_val = FtpActiveSocket.transfer_info("testfile1.txt", 3, 0, true)
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
    
    iex> FtpActiveSocket.get_transfer_status(5, 10)
    "50%"
    iex> FtpActiveSocket.get_transfer_status(8, 10)
    "80%"
  """
  def get_transfer_status(current_transmission_number, no_transmissions) do
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
          current_transmission_number == t1 -> "10%"
          current_transmission_number == t2 -> "20%"
          current_transmission_number == t3 -> "30%"
          current_transmission_number == t4 -> "40%"
          current_transmission_number == t5 -> "50%"
          current_transmission_number == t6 -> "60%"
          current_transmission_number == t7 -> "70%"
          current_transmission_number == t8 -> "80%"
          current_transmission_number == t9 -> "90%"
          true -> :no_status
      end
  end

  ## HELPER FUNCTIONS

  
  @doc """
  Function used to message the FtpData `GenServer` (this GenServer's parent).

  NOT UNIT_TESTABLE
  """
  def message_ftp_data(message) do
    pid = Process.get(:ftp_data_pid)
    Kernel.send(pid, {:from_active_socket, message})
  end


  @doc """
  Function used to send log messages to the FtpLogger `GenServer`. Messages are not send directly to it, but instead follow this path:
  FtpActiveSocket -> FtpData -> FtpServer -> FtpLogger

  This ensures that messages are being logged in order.

  NOT UNIT_TESTABLE
  """
  def logger_debug(message) do
    pid = Process.get(:ftp_data_pid)
    Kernel.send(pid, {:ftp_active_log_message, message})
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
            new_socket_state = close_socket(socket)
            Kernel.send(self(), {:recv_finished, new_socket_state})
        {:error, other_reason} ->
            logger_debug "Error receiving file: #{other_reason}"
    end
  end

  @doc """
  Function used to close the active data socket using `:ranch_tcp.shutdown`.

  NOT UNIT_TESTABLE
  """
  def close_socket(socket) do
    case (socket == nil) do 
          true ->
            logger_debug "Data Socket #{inspect socket} already closed."
            nil
          false ->
              case :ranch_tcp.shutdown(socket, :read_write) do
                  :ok ->
                    logger_debug "Data Socket #{inspect socket} successfully closed."
                    nil
                  {:error, :closed} -> 
                    logger_debug "Data Socket #{inspect socket} already closed."
                    nil
                  {:error, other_reason} -> 
                    logger_debug "Error while attempting to close Data Socket #{inspect socket}. Reason: #{other_reason}."
                    socket
              end
      end
  end

end
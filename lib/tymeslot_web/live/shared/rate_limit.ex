defmodule TymeslotWeb.Live.Shared.RateLimit do
  @moduledoc """
  The rate-limit gate for LiveView and LiveComponent event handlers.

  Each handler performs its own `RateLimiter.check/2`, because limits and
  bucket keys differ per action, and hands the result here together with the
  work to run when it passes. Keeping the refusal path in one place means a
  new action copied from a neighbour cannot lose its rate-limit message, and
  every limited user sees the same kind of response.

      RateLimit.with_rate_limit(RateLimiter.check(:meeting_type_write, user_id), socket, fn ->
        do_toggle(socket, id)
      end)

  ## Options

    * `:message` - replaces the limiter's own message with one written for
      this action.
    * `:flash` - `:parent` (default) forwards the error through
      `TymeslotWeb.Live.Shared.Flash`, which is right for LiveComponents and
      for LiveViews that handle `{:flash, ...}`; `:socket` writes it with
      `put_flash/3`, for LiveViews that render their own flash.
    * `:reply` - `:noreply` (default) returns `{:noreply, socket}` when
      limited, the shape of an event handler; `:socket` returns the bare
      socket, for helpers that a handler pipes through.

  A check refused for an invalid user or id (`{:error, :invalid_user_id}`,
  `{:error, :invalid_id}`) is logged by the limiter and left without a flash:
  it means the socket carries no usable identity, not that the user did
  anything a message could help with.
  """

  alias Phoenix.LiveView
  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Shared.Flash

  @type check_result ::
          :ok
          | {:error, :rate_limited, String.t()}
          | {:error, :invalid_user_id}
          | {:error, :invalid_id}

  @type option ::
          {:message, String.t()} | {:flash, :parent | :socket} | {:reply, :noreply | :socket}

  @doc """
  Runs `action` when `check` is `:ok`; otherwise reports the refusal and
  returns the socket unchanged, in the shape `:reply` names.
  """
  @spec with_rate_limit(check_result(), Socket.t(), (-> result), [option()]) ::
          result | {:noreply, Socket.t()} | Socket.t()
        when result: var
  def with_rate_limit(check, socket, action, opts \\ [])

  def with_rate_limit(:ok, _socket, action, _opts), do: action.()

  def with_rate_limit({:error, :rate_limited, message}, socket, _action, opts) do
    message = Keyword.get(opts, :message, message)

    socket
    |> report(message, Keyword.get(opts, :flash, :parent))
    |> reply(opts)
  end

  def with_rate_limit({:error, reason}, socket, _action, opts)
      when reason in [:invalid_user_id, :invalid_id] do
    reply(socket, opts)
  end

  defp report(socket, message, :parent), do: Flash.put_flash(socket, :error, message)
  defp report(socket, message, :socket), do: LiveView.put_flash(socket, :error, message)

  defp reply(socket, opts) do
    case Keyword.get(opts, :reply, :noreply) do
      :noreply -> {:noreply, socket}
      :socket -> socket
    end
  end
end

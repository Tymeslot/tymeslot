defmodule TymeslotWeb.Live.InitHelpers do
  @moduledoc """
  Shared helpers for LiveView mount callbacks that need to perform common
  initialization such as onboarding checks and client metadata assignment.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Auth
  alias TymeslotWeb.Helpers.ClientIP

  @type mount_result ::
          {:ok, LiveView.Socket.t()}
          | {:ok, LiveView.Socket.t(), keyword()}

  @doc """
  Ensures the current user has completed onboarding and assigns common client
  metadata before executing the provided callback.

  If onboarding is incomplete, returns a redirect tuple pointing to the
  onboarding flow. Otherwise, the given function is invoked with the updated
  socket and its return value is propagated.
  """
  @spec with_user_context(LiveView.Socket.t(), keyword(), (LiveView.Socket.t() -> mount_result())) ::
          mount_result()
  def with_user_context(socket, opts \\ [], fun) when is_function(fun, 1) do
    case guard_onboarding(socket.assigns[:current_user], opts) do
      {:redirect, path} ->
        {:ok, LiveView.redirect(socket, to: path)}

      :ok ->
        socket = maybe_assign_client_metadata(socket, opts)

        fun.(socket)
    end
  end

  defp guard_onboarding(nil, _opts), do: :ok

  defp guard_onboarding(user, opts) do
    if Auth.onboarding_completed?(user) do
      :ok
    else
      {:redirect, Keyword.get(opts, :onboarding_path, "/onboarding")}
    end
  end

  defp maybe_assign_client_metadata(socket, opts) do
    if Keyword.get(opts, :assign_client_metadata?, true) do
      socket
      |> Component.assign_new(:client_ip, fn -> fetch_client_ip(socket, opts) end)
      |> Component.assign_new(:user_agent, fn -> fetch_user_agent(socket, opts) end)
    else
      socket
    end
  end

  defp fetch_client_ip(socket, opts) do
    client_ip_fun = Keyword.get(opts, :client_ip_fun, &ClientIP.get_from_mount/1)
    client_ip_fun.(socket)
  end

  defp fetch_user_agent(socket, opts) do
    user_agent_fun = Keyword.get(opts, :user_agent_fun, &ClientIP.get_user_agent_from_mount/1)
    user_agent_fun.(socket)
  end
end

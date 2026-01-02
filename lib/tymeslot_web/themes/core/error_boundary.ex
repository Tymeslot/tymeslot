defmodule TymeslotWeb.Themes.Core.ErrorBoundary do
  @moduledoc """
  Provides error boundary functionality for theme isolation.

  This module ensures that errors in theme code don't crash the entire
  application, providing graceful degradation and error reporting.
  """

  require Logger

  alias Phoenix.Component

  @type error_context :: %{
          theme_id: String.t(),
          function: atom(),
          args: list(),
          error: term(),
          stacktrace: list()
        }

  @doc """
  Executes a theme function within an error boundary.

  Returns {:ok, result} on success or {:error, error_context} on failure.
  """
  @spec call(String.t(), module(), atom(), list()) :: {:ok, term()} | {:error, error_context()}
  def call(theme_id, module, function, args) do
    result = apply(module, function, args)
    {:ok, result}
  rescue
    error ->
      stacktrace = __STACKTRACE__
      context = build_error_context(theme_id, function, args, error, stacktrace)
      log_theme_error(context)
      {:error, context}
  catch
    kind, error ->
      stacktrace = __STACKTRACE__
      context = build_error_context(theme_id, function, args, {kind, error}, stacktrace)
      log_theme_error(context)
      {:error, context}
  end

  @doc """
  Executes a theme function with a fallback on error.

  Returns the result on success or the fallback value on failure.
  """
  @spec call_with_fallback(String.t(), module(), atom(), list(), (error_context() -> term())) ::
          term()
  def call_with_fallback(theme_id, module, function, args, fallback_fn) do
    apply(module, function, args)
  rescue
    error ->
      stacktrace = __STACKTRACE__
      context = build_error_context(theme_id, function, args, error, stacktrace)
      log_theme_error(context)
      fallback_fn.(context)
  catch
    kind, error ->
      stacktrace = __STACKTRACE__
      context = build_error_context(theme_id, function, args, {kind, error}, stacktrace)
      log_theme_error(context)
      fallback_fn.(context)
  end

  @doc """
  Wraps a LiveView callback to handle theme errors gracefully.
  """
  @spec wrap_callback(String.t(), module(), :mount, list()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def wrap_callback(theme_id, module, :mount, [params, session, socket]) do
    call_with_fallback(theme_id, module, :mount, [params, session, socket], fn context ->
      {:ok, assign_error(socket, context)}
    end)
  end

  @spec wrap_callback(String.t(), module(), :handle_params, list()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def wrap_callback(theme_id, module, :handle_params, [params, url, socket]) do
    call_with_fallback(theme_id, module, :handle_params, [params, url, socket], fn context ->
      {:noreply, assign_error(socket, context)}
    end)
  end

  @spec wrap_callback(String.t(), module(), :handle_event, list()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def wrap_callback(theme_id, module, :handle_event, [event, params, socket]) do
    call_with_fallback(theme_id, module, :handle_event, [event, params, socket], fn context ->
      {:noreply, assign_error(socket, context)}
    end)
  end

  @spec wrap_callback(String.t(), module(), :handle_info, list()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def wrap_callback(theme_id, module, :handle_info, [msg, socket]) do
    call_with_fallback(theme_id, module, :handle_info, [msg, socket], fn context ->
      {:noreply, assign_error(socket, context)}
    end)
  end

  @doc """
  Renders an error view for theme failures.
  """
  @spec render_error(map()) :: map()
  def render_error(assigns) do
    Component.assign(assigns, :formatted_error, format_error(assigns[:theme_error]))
  end

  # Private functions

  defp build_error_context(theme_id, function, args, error, stacktrace) do
    %{
      theme_id: theme_id,
      function: function,
      args: sanitize_args(args),
      error: error,
      stacktrace: stacktrace,
      timestamp: DateTime.utc_now()
    }
  end

  defp sanitize_args(args) do
    # Remove sensitive data from args for logging
    Enum.map(args, fn
      %Phoenix.LiveView.Socket{} -> "%Socket{...}"
      %{} = map when map_size(map) > 10 -> "%{...#{map_size(map)} keys...}"
      arg -> arg
    end)
  end

  defp log_theme_error(context) do
    Logger.error("""
    Theme error in #{context.theme_id}.#{context.function}:
    Error: #{inspect(context.error)}
    Args: #{inspect(context.args)}
    """)

    if Application.get_env(:tymeslot, :debug_theme_errors, false) do
      Logger.error("Stacktrace: #{Exception.format_stacktrace(context.stacktrace)}")
    end
  end

  defp assign_error(socket, context) do
    socket
    |> Component.assign(:theme_error, context)
    |> Component.assign(:theme_error_message, format_error(context))
  end

  defp format_error(%{function: :mount}), do: "Failed to load theme"
  defp format_error(%{function: :handle_params}), do: "Navigation error in theme"
  defp format_error(%{function: :handle_event}), do: "Event handling error in theme"
  defp format_error(%{function: :handle_info}), do: "Message handling error in theme"
  defp format_error(_), do: "An error occurred in the theme"
end

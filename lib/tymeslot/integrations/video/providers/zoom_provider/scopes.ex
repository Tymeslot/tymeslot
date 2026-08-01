defmodule Tymeslot.Integrations.Video.Providers.ZoomProvider.Scopes do
  @moduledoc """
  Zoom OAuth scope rules for the meeting operations Tymeslot performs.

  Zoom apps come in two flavours. Classic apps hold coarse scopes such as
  `meeting:write`, which covers creating, updating and deleting meetings alike.
  Granular apps hold one scope per action — `meeting:write:meeting`,
  `meeting:read:meeting`, `meeting:delete:meeting` — so an app that can create
  a meeting is not thereby allowed to delete one.

  That asymmetry is the whole reason this module exists: checking a write scope
  before a delete waves through a token Zoom then rejects at the API with
  `code 4711`, turning a permanent authorisation gap into a retry loop.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  # Zoom's error code for "the token's grant does not include this scope".
  @missing_scope_code 4711

  @type operation :: :write | :delete

  @doc """
  Returns true when `stored_scope` grants `operation`.

  `stored_scope` is the raw space-delimited scope string recorded when the
  integration was connected.
  """
  @spec satisfied?(String.t(), operation()) :: boolean()
  def satisfied?(stored_scope, :write) do
    granular?(stored_scope) or classic?(stored_scope)
  end

  def satisfied?(stored_scope, :delete) do
    if granular?(stored_scope) do
      String.contains?(stored_scope, "meeting:delete:meeting")
    else
      classic?(stored_scope)
    end
  end

  @doc """
  Human-readable description of what `operation` requires, for log lines.
  """
  @spec required_description(operation()) :: String.t()
  def required_description(:write), do: "meeting:write or meeting:write:meeting"
  def required_description(:delete), do: "meeting:write or meeting:delete:meeting"

  @doc """
  Phrase naming what the user loses while `operation` is unauthorised, for the
  "Reconnect required" message shown on the dashboard.
  """
  @spec action_phrase(operation()) :: String.t()
  def action_phrase(:write),
    do: dgettext("dashboard_integrations", "create and update meetings")

  def action_phrase(:delete), do: dgettext("dashboard_integrations", "cancel meetings")

  @doc """
  Detects Zoom's `4711` response, which means the token's grant predates a
  scope the request needs. Retrying cannot widen an existing grant; only the
  user re-consenting can.
  """
  @spec rejection?(term()) :: boolean()
  def rejection?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> rejection?(decoded)
      {:error, _reason} -> false
    end
  end

  def rejection?(%{"code" => @missing_scope_code}), do: true
  def rejection?(_body), do: false

  defp granular?(stored_scope), do: String.contains?(stored_scope, "meeting:write:meeting")

  # Matches a whole space-delimited scope token exactly, so a search for the
  # classic `meeting:write` is not satisfied by an unrelated longer scope that
  # merely contains it as a substring.
  defp classic?(stored_scope) do
    stored_scope
    |> String.split(~r/\s+/, trim: true)
    |> Enum.member?("meeting:write")
  end
end

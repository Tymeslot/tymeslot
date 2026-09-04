defmodule Tymeslot.Integrations.Video.Providers.ZoomProvider.Scopes do
  @moduledoc """
  Zoom OAuth scope rules for the meeting operations Tymeslot performs.

  Zoom apps come in two flavours. Classic apps hold coarse scopes such as
  `meeting:write`, which covers creating, updating and deleting meetings alike.
  Granular apps hold one scope per action — `meeting:write:meeting` creates,
  `meeting:update:meeting` reschedules, `meeting:delete:meeting` cancels — so
  an app that can create a meeting is not thereby allowed to change or delete
  one.

  That asymmetry is the whole reason this module exists: checking a create
  scope before a reschedule or a cancellation waves through a token Zoom then
  rejects at the API with `code 4711`, turning a permanent authorisation gap
  into a retry loop.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  # Zoom's error code for "the token's grant does not include this scope".
  @missing_scope_code 4711

  # One granular scope per operation. Zoom's account-level variants suffix the
  # user-level name (`meeting:update:meeting:admin`), so a substring test
  # accepts an admin grant for the same operation without listing it here.
  @granular_scopes %{
    write: "meeting:write:meeting",
    update: "meeting:update:meeting",
    delete: "meeting:delete:meeting"
  }

  # Scopes that are not tied to one meeting operation.
  @read_scopes ["meeting:read:meeting", "user:read:user"]

  # The operations Tymeslot always asks Zoom for. `:update` is conditional and
  # lives behind `:zoom_update_scope_enabled` instead, because whether it can be
  # obtained is a property of the Marketplace app behind a given deployment, not
  # of this code.
  #
  # Zoom gives no signal when an app lacks a requested scope: the authorize
  # request is not rejected, the scope is silently dropped, the rest is
  # consented to, and the shortfall first surfaces as a 4711 on the API call
  # that needed it. So a deployment whose app is not configured for
  # `meeting:update:meeting` must not request it — not because requesting fails,
  # but because requesting it would make the rest of the system believe the
  # scope is obtainable and start asking users to reconnect to get a scope no
  # reconnect can produce.
  #
  # Enable it (`ZOOM_UPDATE_SCOPE_ENABLED=true`) only where the Zoom app is
  # actually configured for the scope. The authorize request, the pre-flight,
  # and whether users are asked to reconnect all follow from this one setting.
  @always_requested [:write, :delete]

  @type operation :: :write | :update | :delete

  @doc """
  Every operation Tymeslot performs against a Zoom meeting, in lifecycle order.
  """
  @spec operations() :: [operation()]
  def operations, do: [:write, :update, :delete]

  @doc """
  The operations this deployment asks Zoom for, in lifecycle order.
  """
  @spec requested_operations() :: [operation()]
  def requested_operations do
    Enum.filter(operations(), &requestable?/1)
  end

  @doc """
  Whether this deployment asks Zoom for the scope `operation` needs.

  `false` means no user can be holding that scope, however recently they
  connected, so the gap is the Zoom app's and reconnecting cannot close it.
  Callers use this to tell an operator problem apart from a stale grant, and
  must not ask a user to reconnect when it returns `false`.
  """
  @spec requestable?(operation()) :: boolean()
  def requestable?(:update), do: update_scope_enabled?()
  def requestable?(operation), do: operation in @always_requested

  @doc """
  The space-delimited scope string sent with the authorize request.

  Read it per request rather than freezing it at compile time: the setting it
  derives from is a deployment's property and is read from the environment at
  boot.
  """
  @spec requested_scope() :: String.t()
  def requested_scope do
    requested_operations()
    |> Enum.map(&Map.fetch!(@granular_scopes, &1))
    |> Enum.concat(@read_scopes)
    |> Enum.join(" ")
  end

  defp update_scope_enabled? do
    Application.get_env(:tymeslot, :zoom_update_scope_enabled, false) == true
  end

  @doc """
  Returns true when `stored_scope` grants `operation`.

  `stored_scope` is the raw space-delimited scope string recorded when the
  integration was connected.

  Classic `meeting:write` authorises every one of these operations on its own,
  so it satisfies the check even when granular scopes are also present — a
  hybrid grant must not be held to a granular scope the classic one already
  covers.
  """
  @spec satisfied?(String.t(), operation()) :: boolean()
  def satisfied?(stored_scope, operation) do
    String.contains?(stored_scope, Map.fetch!(@granular_scopes, operation)) or
      classic?(stored_scope)
  end

  @doc """
  Human-readable description of what `operation` requires, for log lines.
  """
  @spec required_description(operation()) :: String.t()
  def required_description(operation) do
    "meeting:write or " <> Map.fetch!(@granular_scopes, operation)
  end

  @doc """
  The "Reconnect required" message the account owner reads on the dashboard
  while `operation` is unauthorised.

  Both the runtime rejection path and the nightly audit flag integrations with
  this, so the wording a user sees does not depend on which one noticed first.
  """
  @spec reauth_message(operation()) :: String.t()
  def reauth_message(operation) do
    dgettext(
      "dashboard_integrations",
      "Zoom is missing the permission needed to %{action}. Please reconnect your Zoom account.",
      action: action_phrase(operation)
    )
  end

  # Phrase naming what the user loses while `operation` is unauthorised.
  defp action_phrase(:write), do: dgettext("dashboard_integrations", "create meetings")

  defp action_phrase(:update), do: dgettext("dashboard_integrations", "reschedule meetings")

  defp action_phrase(:delete), do: dgettext("dashboard_integrations", "cancel meetings")

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

  # Matches a whole space-delimited scope token exactly, so a search for the
  # classic `meeting:write` is not satisfied by an unrelated longer scope that
  # merely contains it as a substring.
  defp classic?(stored_scope) do
    stored_scope
    |> String.split(~r/\s+/, trim: true)
    |> Enum.member?("meeting:write")
  end
end

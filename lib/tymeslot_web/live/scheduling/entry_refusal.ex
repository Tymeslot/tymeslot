defmodule TymeslotWeb.Live.Scheduling.EntryRefusal do
  @moduledoc """
  Why the booking flow turned a guest away at its entry, and how the page it
  sends them to says so.

  The entry (`TymeslotWeb.Themes.Shared.LiveHelpers.StepEntry`) refuses a
  meeting type it cannot open: one the organiser has no type for, one with no
  times open, or an invitation-only type without a valid link
  (`InvitationMessages`). It flashes the reason and redirects to the
  organiser's profile.

  Inside an embed the flash never arrives: `EmbedTokenPlug` ignores the
  session on embed requests, so the cookie that would carry it is not
  written. There the redirect carries the reason in the URL instead
  (`put_param/3`), and the profile it lands on flashes it again (`flash/2`).
  The code does not outlive the arrival: the page's own patch as it connects
  (`ChoicesInUrl`) rewrites the URL from the visitor's choices, which never
  carry it, so a reload does not say it again.

  The parameter is a closed set of codes, each mapped to its translated copy
  on the server, so it can never put text of the URL's choosing on someone's
  booking page. Outside an embed the session flash works and stays the only
  path: the parameter is neither written nor read there.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]

  alias TymeslotWeb.Live.Scheduling.InvitationMessages

  @type reason :: :invalid_type | :no_times_open | InvitationMessages.reason()

  @param "refused"

  @codes %{
    invalid_type: "invalid-type",
    no_times_open: "no-times-open",
    used: "invitation-used",
    expired: "invitation-expired",
    revoked: "invitation-revoked",
    required: "invitation-required"
  }

  @reasons Map.new(@codes, fn {reason, code} -> {code, reason} end)

  @doc "The query parameter the refusal travels in."
  @spec param() :: String.t()
  def param, do: @param

  @doc "Flashes the guest's copy for `reason` on `socket`."
  @spec put(Phoenix.LiveView.Socket.t(), reason()) :: Phoenix.LiveView.Socket.t()
  def put(socket, reason), do: put_flash(socket, kind(reason), message(reason))

  @doc """
  Adds `reason` to the `query` of the redirect away from a refused entry, when
  `socket` is a verified embed; any other page's query is left untouched.
  """
  @spec put_param(map(), Phoenix.LiveView.Socket.t(), reason()) :: map()
  def put_param(query, %{assigns: %{embedded: true}}, reason),
    do: Map.put(query, @param, Map.fetch!(@codes, reason))

  def put_param(query, _not_embedded, _reason), do: query

  @doc """
  Flashes the refusal a redirect carried in `params`, on the profile of a
  verified embed only, the one page a refusal sends the guest to. An unknown
  code, another step, or a page that is not embedded flashes nothing.
  """
  @spec flash(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def flash(%{assigns: %{embedded: true, live_action: :overview}} = socket, %{@param => code}) do
    case Map.fetch(@reasons, code) do
      {:ok, reason} -> put(socket, reason)
      :error -> socket
    end
  end

  def flash(socket, _params), do: socket

  # A type with no times open is not the guest's mistake.
  defp kind(:no_times_open), do: :info
  defp kind(_refusal), do: :error

  defp message(:invalid_type), do: dgettext("booking", "Invalid meeting type")

  defp message(:no_times_open),
    do: dgettext("booking", "This meeting type has no times open for booking right now.")

  defp message(invitation_refusal), do: InvitationMessages.message(invitation_refusal)
end

defmodule TymeslotWeb.Dashboard.Polls.PollShareLink do
  @moduledoc """
  The gated "copy voting link" control, shared by the poll list card and the
  results panel.

  Both surfaces offer the same action on the same poll, so the URL construction
  and the access gate live here once rather than as two copies that drift. A
  host with no username, or without the integrations `LinkAccessPolicy`
  requires, gets a disabled control that explains itself instead of a link that
  would 403 when a guest opened it.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Components.CoreComponents.Icons

  @doc """
  Renders the copy-to-clipboard button for a poll's public voting link.

  `id` is caller-supplied because the list card and the results panel can be on
  screen for the same poll at once, and `phx-hook` needs a unique DOM id.
  """
  attr :poll, :map, required: true
  attr :profile, :any, required: true
  attr :integration_status, :map, required: true
  attr :id, :string, required: true

  @spec copy_link_button(map()) :: Phoenix.LiveView.Rendered.t()
  def copy_link_button(assigns) do
    assigns =
      assigns
      |> assign(
        :can_link?,
        LinkAccessPolicy.can_link?(assigns.profile, assigns.integration_status)
      )
      |> assign(:share_url, share_url(assigns.profile, assigns.poll))

    ~H"""
    <button
      :if={@can_link?}
      id={@id}
      type="button"
      phx-hook="CopyOnClick"
      data-copy-text={@share_url}
      data-copy-feedback={dgettext("dashboard_common", "Poll link copied to clipboard!")}
      class="p-2 rounded-lg bg-white border-2 border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-400 hover:text-turquoise-700 transition-colors"
      title={dgettext("dashboard_common", "Copy poll link to clipboard")}
    >
      <Icons.icon name="hero-clipboard" class="w-4 h-4" />
    </button>
    <button
      :if={!@can_link?}
      type="button"
      aria-disabled="true"
      aria-label={LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
      class="p-2 rounded-lg bg-tymeslot-100 text-tymeslot-400 cursor-not-allowed opacity-60"
      title={LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
    >
      <Icons.icon name="hero-clipboard" class="w-4 h-4" />
    </button>
    """
  end

  @doc """
  The public voting URL for a poll, or `nil` when the host has no username to
  build one from.
  """
  @spec share_url(map(), map()) :: String.t() | nil
  def share_url(%{username: username}, poll)
      when is_binary(username) and username != "" do
    UrlBuilder.build_url("/#{username}/poll/#{poll.token}")
  end

  def share_url(_profile, _poll), do: nil
end

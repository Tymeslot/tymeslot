defmodule TymeslotWeb.Dashboard.BookingLinkShare do
  @moduledoc """
  Reports that a host copied a link to their own booking page from the dashboard.

  The `CopyOnClick` hook copies client-side and never talks to the server, so
  each copy button also carries a `phx-click="booking_link_copied"`; the
  handlers call `record/3`, which remembers the first share on the profile and
  announces it to analytics. Copy buttons for anything other than the host's own
  booking page (poll links, webhook secrets) must not use it.
  """

  alias Tymeslot.Analytics.Contract
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.Analytics

  @doc """
  Stamps the profile's first share and pushes `booking_link_shared` with the
  given channel, one of `Tymeslot.Analytics.Contract.share_channels/0`, fixed
  by the caller.
  """
  @spec record(Phoenix.LiveView.Socket.t(), ProfileSchema.t() | nil, String.t()) ::
          Phoenix.LiveView.Socket.t()
  def record(socket, %ProfileSchema{} = profile, channel) do
    {:ok, _outcome} = Profiles.mark_booking_link_shared(profile)
    Analytics.push(socket, "booking_link_shared", %{channel: channel})
  end

  def record(socket, nil, _channel), do: socket

  @doc """
  The `booking_link_copied` event for LiveViews that render the dashboard layout.

  The channel comes from the client, so anything outside the contract's
  share channels is ignored rather than reported.
  """
  @spec handle_copied(Phoenix.LiveView.Socket.t(), term()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_copied(socket, channel) do
    if channel in Contract.share_channels(),
      do: {:noreply, record(socket, socket.assigns[:profile], channel)},
      else: {:noreply, socket}
  end
end

defmodule TymeslotWeb.Themes.Shared.PollVotingLocation do
  @moduledoc """
  Where a poll's meeting will be held, as the voting page names it
  (`Tymeslot.Polls.location/1`), under the poll's description in every
  theme family. Styled by the shared poll CSS (`poll-voting-location`).
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  attr :location, :map, required: true

  @doc """
  The place, or for a video call that its link follows once a time is
  confirmed, since the room is only created then. Nothing without a
  location, which may decide whether someone can come at all.
  """
  @spec location(map()) :: Phoenix.LiveView.Rendered.t()
  def location(%{location: nil} = assigns), do: ~H""

  def location(assigns) do
    ~H"""
    <p class="poll-voting-location" data-testid="poll-location">
      <.icon
        name={if @location.kind == :video, do: "hero-video-camera", else: "hero-map-pin"}
        class="poll-voting-location-icon"
      />
      <span :if={@location.kind == :video}>
        {dgettext("booking_polls", "Video call. The link follows once a time is confirmed.")}
      </span>
      <span :if={@location.kind != :video}>{@location.place}</span>
    </p>
    """
  end
end

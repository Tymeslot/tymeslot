defmodule TymeslotWeb.Themes.Rhythm.Poll.Voting do
  @moduledoc """
  Rhythm theme rendering of the public poll voting page.

  Wraps the shared, theme-neutral `PollVotingComponents` in Rhythm's
  video-background sliding shell; all styling comes from the theme's `polls.css`
  module.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.PollVotingComponents

  attr :theme_customization, :map, required: true
  attr :custom_css, :string, required: true
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true
  attr :poll, :map, required: true
  attr :tallies, :map, required: true
  attr :voting_open, :boolean, required: true
  attr :participant, :map, default: nil

  @doc "Renders the poll voting page in Rhythm theme style."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.rhythm_wrapper
      theme_customization={@theme_customization}
      custom_css={@custom_css}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <div class="scheduling-box poll-voting-page rhythm-poll-voting">
        <div class="slide-container">
          <div class="slide active">
            <div class="slide-content">
              <PollVotingComponents.poll_content
                poll={@poll}
                tallies={@tallies}
                voting_open={@voting_open}
                participant={@participant}
              />
            </div>
          </div>
        </div>
      </div>
    </Wrapper.rhythm_wrapper>
    """
  end
end

defmodule TymeslotWeb.Themes.Quill.Poll.Voting do
  @moduledoc """
  Quill theme rendering of the public poll voting page.

  Wraps the shared, theme-neutral `PollVotingComponents` in Quill's glass-morphism
  shell. The styling is shared by every theme, in
  `assets/css/scheduling/shared/components/polls.css`; Quill sets its look
  through the `--poll-*` tokens in its `variables.css`.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.PollVotingComponents

  use TymeslotWeb.Components.CoreComponents, only: [glass_morphism_card: 1]

  attr :theme_tokens, :any, required: true
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true
  attr :poll, :map, required: true
  attr :tallies, :map, required: true
  attr :voting_open, :boolean, required: true
  attr :participant, :map, default: nil

  @doc "Renders the poll voting page in Quill theme style."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.quill_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <div class="poll-voting-page quill-poll-voting min-h-screen flex items-center justify-center px-4 py-8">
        <div class="w-full max-w-2xl">
          <.glass_morphism_card class="booker-card">
            <div class="p-8">
              <PollVotingComponents.poll_content
                poll={@poll}
                tallies={@tallies}
                voting_open={@voting_open}
                participant={@participant}
              />
            </div>
          </.glass_morphism_card>
        </div>
      </div>
    </Wrapper.quill_wrapper>
    """
  end
end

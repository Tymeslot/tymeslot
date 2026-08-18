defmodule TymeslotWeb.Themes.Quill.Poll.Voting do
  @moduledoc """
  Quill theme rendering of the public poll voting page.

  Wraps the shared, theme-neutral `PollVotingComponents` in Quill's glass-morphism
  shell; all styling comes from the theme's `polls.css` module.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.PollVotingComponents

  import TymeslotWeb.Components.CoreComponents, only: [glass_morphism_card: 1]

  attr :theme_customization, :map, required: true
  attr :custom_css, :string, required: true
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
      theme_customization={@theme_customization}
      custom_css={@custom_css}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <div class="poll-voting-page quill-poll-voting min-h-screen flex items-center justify-center px-4 py-8">
        <div class="w-full max-w-2xl">
          <.glass_morphism_card>
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

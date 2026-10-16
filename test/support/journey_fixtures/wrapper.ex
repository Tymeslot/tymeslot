defmodule TymeslotWeb.Test.JourneyFixtures.Wrapper do
  @moduledoc """
  The journey fixtures' wrappers: the shared `ThemeShell` with no background
  and no page grid, the chrome, the moments and the theme extensions straight
  inside the booker root; one function per fixture so each passes its own
  theme id and wrapper class.
  """
  use Phoenix.Component

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell

  import TymeslotWeb.Themes.Shared.Customization.Helpers, only: [prepare_wrapper_assigns: 1]

  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :current_state, :atom, default: nil
  attr :journey, :any, default: nil, doc: "the page's journey: its navigator decides the switcher"
  attr :language_dropdown_open, :boolean, default: nil
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false
  attr :show_language_switcher, :boolean, default: nil
  attr :owner_preview, :boolean, default: false
  attr :demo_mode, :boolean, doc: "handed to the theme extensions only when given"
  slot :inner_block, required: true

  @doc "Fixture Scroll's wrapper."
  @spec scroll(map()) :: Phoenix.LiveView.Rendered.t()
  def scroll(assigns), do: shell(assigns, :fixture_scroll, "journey-fixture-scroll")

  @doc "Fixture Talk's wrapper."
  @spec talk(map()) :: Phoenix.LiveView.Rendered.t()
  def talk(assigns), do: shell(assigns, :fixture_talk, "journey-fixture-talk")

  @doc "Fixture Express's wrapper."
  @spec express(map()) :: Phoenix.LiveView.Rendered.t()
  def express(assigns), do: shell(assigns, :fixture_express, "journey-fixture-express")

  defp shell(assigns, key, class) do
    {:ok, theme_id} = Catalog.key_to_id(key)

    assigns =
      assigns
      |> prepare_wrapper_assigns()
      |> assign(theme_id: theme_id, wrapper_class: class)

    ~H"""
    <ThemeShell.theme_shell class={@wrapper_class} locale={@locale} theme_tokens={@theme_tokens}>
      <ThemeShell.chrome
        language_class="journey-fixture-language"
        locale={@locale}
        language_dropdown_open={@language_dropdown_open}
        show_language_switcher={@show_language_switcher}
        owner_preview={@owner_preview}
      />
      {render_slot(@inner_block)}
      <ThemeShell.extensions
        theme_id={@theme_id}
        organizer_user_id={@organizer_user_id}
        should_show_branding={@should_show_branding}
        {Map.take(assigns, [:demo_mode])}
      />
    </ThemeShell.theme_shell>
    """
  end
end

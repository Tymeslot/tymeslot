defmodule TymeslotWeb.Themes.Folio.Scheduling.Wrapper do
  @moduledoc """
  Folio's wrapper: the shared `ThemeShell` on the scheme's canvas, with no
  background of its own (the cover belongs to each step's card).

  It marks the page `folio-theme-wrapper--light` or `--dark` (`mode/1`), the
  one thing Folio's CSS cannot derive from the palette's custom properties:
  the `color-scheme` that form controls and scrollbars follow.
  """
  use Phoenix.Component

  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Utils.Colour
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell

  import TymeslotWeb.Themes.Shared.Customization.Helpers, only: [prepare_wrapper_assigns: 1]

  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :current_state, :atom, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false
  attr :show_language_switcher, :boolean, default: nil
  attr :owner_preview, :boolean, default: false
  attr :demo_mode, :boolean, doc: "handed to the theme extensions only when given"
  slot :inner_block, required: true

  @spec folio_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def folio_wrapper(assigns) do
    assigns =
      assigns
      |> prepare_wrapper_assigns()
      |> assign(theme_id: theme_id(), mode: mode(assigns.theme_tokens))

    ~H"""
    <ThemeShell.theme_shell
      class={["folio-theme-wrapper", "folio-theme-wrapper--#{@mode}"]}
      grid_class="folio-page"
      language_class="folio-language"
      theme_id={@theme_id}
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={@show_language_switcher}
      owner_preview={@owner_preview}
      organizer_user_id={@organizer_user_id}
      should_show_branding={@should_show_branding}
      {Map.take(assigns, [:demo_mode])}
    >
      {render_slot(@inner_block)}
    </ThemeShell.theme_shell>
    """
  end

  @doc """
  Whether the page's palette is dark (its canvas darker than its text) or
  light; light when there are no tokens to read, as on the payment pages.
  """
  @spec mode(Tokens.t() | nil) :: :light | :dark
  def mode(%Tokens{vars: %{"--theme-canvas" => canvas, "--theme-text" => text}})
      when is_binary(canvas) and is_binary(text) do
    if Colour.relative_luminance(canvas) < Colour.relative_luminance(text),
      do: :dark,
      else: :light
  end

  def mode(_tokens), do: :light

  defp theme_id do
    {:ok, id} = Catalog.key_to_id(:folio)
    id
  end
end

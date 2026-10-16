defmodule TymeslotWeb.Themes.Core.Theme do
  @moduledoc """
  `use` this to define a booking theme module.

      defmodule TymeslotWeb.Themes.Quill.Theme do
        use TymeslotWeb.Themes.Core.Theme,
          live_view: TymeslotWeb.Themes.Quill.Scheduling.Live,
          preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
          description: dgettext_noop("dashboard_appearance", "…"),
          story: dgettext_noop("dashboard_appearance", "…"),
          axes: [flow: :paged_wizard, entry: :meeting_type_first, ...]
      end

  It declares `TymeslotWeb.Themes.Core.Behaviour` and generates:

    * `live_view_module/0`, returning `:live_view`;
    * `metadata/0`, returning `:preview_image` and `:description` translated
      into the current locale. The description must be a `dgettext_noop/2`
      call, so extraction registers it and the lookup knows its domain;
    * `story/0`, the `:story` option (required) translated into the current
      locale: the theme's persona in the organiser's own words, one
      sentence. Like the description it must be a `dgettext_noop/2` call,
      in the description's domain;
    * `axes/0`, the `:axes` option (required): one value on each of the
      seven design axes, checked against `TymeslotWeb.Themes.Core.Axes`
      while the theme compiles and returned in the canonical order;
    * the render callbacks, dispatching to the conventional modules under the
      theme's namespace, each with a `render/1`: `Meeting.Reschedule`,
      `Meeting.Cancel`, `Meeting.CancelConfirmed`, `Poll.Voting`,
      `Payment.Processing` and `Payment.Cancelled`; or, when `:page_shell`
      names a function component (`page_shell: &MyTheme.Pages.page_shell/1`),
      the six pages from `TymeslotWeb.Themes.Shared.DefaultPages`, the
      shared bodies inside that shell: a theme then writes no page modules
      at all;
    * `onboarding_preview/1`, defaulting to the generic mock in
      `TymeslotWeb.OnboardingLive.PreviewParts`;
    * `option_panels/0`, returning `:option_panels` (default `%{}`): the
      dashboard panels for the theme's own option groups,
      `%{group_module => panel_module}`;
    * `voice/0`, returning `:voice` (default `nil`): the module implementing
      `TymeslotWeb.Themes.Shared.Voice` that words the shared booking lines
      for this theme; without one the theme keeps the shared wording.

  Every render callback is overridable; an override carries
  `@impl TymeslotWeb.Themes.Core.Behaviour` like any other callback. A
  conventional module that neither exists nor is overridden is an
  undefined-module warning, so a missing page fails the build rather than a
  request.
  """

  # Aliased here, outside the quote, so the generated default expands to the
  # full module name and nothing is aliased inside the theme module.
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Core.Axes
  alias TymeslotWeb.Themes.Shared.DefaultPages

  @doc false
  defmacro __using__(opts) do
    live_view = Keyword.fetch!(opts, :live_view)
    preview_image = Keyword.fetch!(opts, :preview_image)
    {description, domain} = translatable!(Keyword.fetch!(opts, :description), :description)
    {story, story_domain} = translatable!(required!(opts, :story), :story)
    same_domain!(story_domain, domain)
    axes = required!(opts, :axes)
    renders = renders(Keyword.get(opts, :page_shell), __CALLER__.module)
    option_panels = Keyword.get(opts, :option_panels, Macro.escape(%{}))
    voice = Keyword.get(opts, :voice)

    quote do
      @behaviour TymeslotWeb.Themes.Core.Behaviour

      use Gettext, backend: TymeslotWeb.Gettext

      @impl TymeslotWeb.Themes.Core.Behaviour
      def live_view_module, do: unquote(live_view)

      @impl TymeslotWeb.Themes.Core.Behaviour
      def metadata do
        %{
          preview_image: unquote(preview_image),
          description:
            Gettext.dgettext(TymeslotWeb.Gettext, unquote(domain), unquote(description))
        }
      end

      @impl TymeslotWeb.Themes.Core.Behaviour
      def story, do: Gettext.dgettext(TymeslotWeb.Gettext, unquote(domain), unquote(story))

      # Checked in the theme's own body, not by this macro, so the compile-time
      # dependency on Axes is the theme's: this module keeps none of its own,
      # and a theme's compile edge to it stays out of the compile-connected
      # graph.
      @theme_axes Axes.validate!(unquote(axes))

      @impl TymeslotWeb.Themes.Core.Behaviour
      def axes, do: @theme_axes

      unquote(renders)

      @impl TymeslotWeb.Themes.Core.Behaviour
      def onboarding_preview(assigns), do: PreviewParts.generic(assigns)

      @impl TymeslotWeb.Themes.Core.Behaviour
      def option_panels, do: unquote(option_panels)

      @impl TymeslotWeb.Themes.Core.Behaviour
      def voice, do: unquote(voice)

      defoverridable render_meeting_action: 2,
                     render_poll_action: 1,
                     render_payment_page: 2,
                     onboarding_preview: 1
    end
  end

  # With a :page_shell, the shared bodies inside the theme's shell; without
  # one, the conventional modules beside the theme module.
  defp renders(nil, theme_module) do
    reschedule = conventional(theme_module, ["Meeting", "Reschedule"])
    cancel = conventional(theme_module, ["Meeting", "Cancel"])
    cancel_confirmed = conventional(theme_module, ["Meeting", "CancelConfirmed"])
    poll = conventional(theme_module, ["Poll", "Voting"])
    processing = conventional(theme_module, ["Payment", "Processing"])
    cancelled = conventional(theme_module, ["Payment", "Cancelled"])

    quote do
      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_meeting_action(assigns, :reschedule), do: unquote(reschedule).render(assigns)
      def render_meeting_action(assigns, :cancel), do: unquote(cancel).render(assigns)

      def render_meeting_action(assigns, :cancel_confirmed),
        do: unquote(cancel_confirmed).render(assigns)

      def render_meeting_action(_assigns, action),
        do: raise("Unsupported meeting action: #{action}")

      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_poll_action(assigns), do: unquote(poll).render(assigns)

      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_payment_page(assigns, :processing), do: unquote(processing).render(assigns)
      def render_payment_page(assigns, :cancelled), do: unquote(cancelled).render(assigns)
    end
  end

  defp renders(page_shell, _theme_module) do
    quote do
      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_meeting_action(assigns, action),
        do: DefaultPages.meeting_action(assigns, action, unquote(page_shell))

      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_poll_action(assigns), do: DefaultPages.poll(assigns, unquote(page_shell))

      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_payment_page(assigns, page),
        do: DefaultPages.payment(assigns, page, unquote(page_shell))
    end
  end

  # The conventional module beside the theme module:
  # `TymeslotWeb.Themes.Quill.Theme` and `["Poll", "Voting"]` give
  # `TymeslotWeb.Themes.Quill.Poll.Voting`. `Module.safe_concat/1` cannot be
  # used, since the compiler may not have loaded that module yet. The segments
  # are the fixed convention above, never user input, so the atoms are bounded.
  defp conventional(theme_module, segments) do
    theme_module
    |> Module.split()
    |> Enum.drop(-1)
    |> Kernel.++(segments)
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    |> Module.concat()
  end

  defp translatable!({:dgettext_noop, _meta, [domain, msgid]} = ast, _option)
       when is_binary(domain) and is_binary(msgid),
       do: {ast, domain}

  defp translatable!(other, option) do
    raise ArgumentError,
          "the #{inspect(option)} option of use TymeslotWeb.Themes.Core.Theme must be a " <>
            "dgettext_noop/2 call with a literal domain and msgid, got: " <>
            Macro.to_string(other)
  end

  # A theme is described by its persona: a story and its seven axes. A theme
  # that has neither has not been designed yet.
  defp required!(opts, option) do
    case Keyword.fetch(opts, option) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "use TymeslotWeb.Themes.Core.Theme needs #{inspect(option)}: a theme starts " <>
                "from its persona, a one-sentence story and a value on each design axis " <>
                "(TymeslotWeb.Themes.Core.Axes)"
    end
  end

  defp same_domain!(domain, domain), do: :ok

  defp same_domain!(story_domain, description_domain) do
    raise ArgumentError,
          "the :story option of use TymeslotWeb.Themes.Core.Theme must be in the same domain " <>
            "as the :description (#{inspect(description_domain)}), got: #{inspect(story_domain)}"
  end
end

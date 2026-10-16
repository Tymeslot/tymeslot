defmodule TymeslotWeb.Themes.Shared.SchedulingLive do
  @moduledoc """
  Shared LiveView macro for scheduling themes.

  A theme passes its wrapper component and its journey, and gets a `render/1`
  that handles every state the booking can be in. The classic journey, the
  five steps Quill and Rhythm show, is one LiveComponent per step:

      defmodule MyTheme.Scheduling.Live do
        alias MyTheme.Scheduling.Components.{
          BookingComponent,
          ConfirmationComponent,
          CustomQuestionsComponent,
          OverviewComponent,
          ScheduleComponent
        }

        alias MyTheme.Scheduling.Wrapper

        use TymeslotWeb.Themes.Shared.SchedulingLive,
          wrapper: &Wrapper.my_wrapper/1,
          steps: %{
            overview: OverviewComponent,
            schedule: ScheduleComponent,
            questions: CustomQuestionsComponent,
            booking: BookingComponent,
            confirmation: ConfirmationComponent
          }
      end

  Any other journey is written out (`TymeslotWeb.Themes.Shared.Journey`):

      use TymeslotWeb.Themes.Shared.SchedulingLive,
        wrapper: &Wrapper.my_wrapper/1,
        journey: [
          navigator: Paged,
          moments: [
            {:now,
             collects: [:meeting_type, :slot],
             component: NowComponent,
             defaults: [meeting_type: :first]},
            {:you, collects: [:answers, :attendee], component: YouComponent}
          ],
          outcomes: %{confirmation: ConfirmationComponent, awaiting_payment: :shared}
        ]

  A theme gives `steps:` or `journey:`, never both; `steps:` is
  `Journey.classic/1` of its map. Either is literal data (atoms, lists,
  tuples, maps and module names), checked while the theme compiles
  (`Journey.build!/2`): a fact asked before one it needs, a component that is
  not a LiveComponent or an unknown default fails the build, naming the
  problem (`defaults:` are checked now and applied once the runtime opens
  moments). The macro generates `__journey__/0`, the theme's `%Journey{}`, and
  assigns it as `:journey` on mount and on every `handle_params/3`.

  The aliases must come before `use`: the options are expanded where `use` is
  written. One optional hook, a multi-clause `defp`:
  `handle_theme_event/3`, for events of the theme's own. A step template's
  `phx-click="theme:<name>"`, from any step, arrives as `<name>` with its
  params (the step on screen is `socket.assigns.current_state`), and so does
  one sent to the LiveView itself. An override replaces the default clause
  wholesale, and any visitor can send `theme:<anything>`, so it ends with a
  catch-all clause calling `super/3`, which logs the name and returns
  `{:noreply, socket}`; without one, an unknown name raises.

  Step events are routed by `Journey.Runtime.handle_step_event/4`: an event
  it does not take (an unknown name, or a canonical one from a moment not on
  screen) is dropped with a warning (`StepEvents.log_ignored/3`), as is an
  event no hook clause takes, and a message nothing routes is logged and
  ignored (`InfoHandlers.handle_unexpected/2`).

  The macro also generates `handle_async/3` for the flow's `start_async/3`
  results (a week view's week of slots,
  `TymeslotWeb.Live.Scheduling.WeekSlots`); a theme writes none.
  """

  @steps [:overview, :schedule, :questions, :booking, :confirmation]

  # The generated code names every module in full rather than through an
  # alias, which would also apply to the theme's own code (see `__using__/1`).
  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, [:wrapper, :steps, :journey])
    wrapper = Keyword.fetch!(opts, :wrapper)
    journey = journey!(opts, __CALLER__)

    quote do
      use TymeslotWeb, :live_view

      # Module names are written in full here, never through an alias of
      # this code's own, which would also apply to the theme's code around
      # it. The theme's journey, built from the literal `use` was given with
      # its aliases already resolved, as it was checked when the theme
      # compiled.
      @doc false
      @spec __journey__() :: TymeslotWeb.Themes.Shared.Journey.t()
      def __journey__, do: TymeslotWeb.Themes.Shared.Journey.new(unquote(journey))

      @impl Phoenix.LiveView
      def mount(params, _session, socket) do
        socket =
          socket
          |> assign(:journey, __journey__())
          |> TymeslotWeb.Themes.Shared.LiveHelpers.Mount.mount_scheduling_view(params)
          |> TymeslotWeb.Themes.Shared.LiveHelpers.Tracking.assign_tracking(params)

        {:ok, socket}
      end

      @impl Phoenix.LiveView
      # From `__journey__/0`, not `assigns.journey`: an error page renders
      # before mount has assigned it.
      def render(assigns),
        do:
          TymeslotWeb.Themes.Shared.SchedulingPage.render(
            assigns,
            unquote(wrapper),
            __journey__()
          )

      # Assigned again: the dispatcher may hand the page to another theme on
      # a patch (`?theme=`), and the journey is the rendering theme's.
      @impl Phoenix.LiveView
      def handle_params(params, _url, socket),
        do:
          socket
          |> assign(:journey, __journey__())
          |> TymeslotWeb.Themes.Shared.LiveHelpers.Mount.handle_scheduling_params(params)

      # A theme's own event (`theme:<name>`, relayed untouched by the step
      # relays) goes to the theme's hook without its prefix, from any step;
      # the flow never sees it, so it cannot stand in for a canonical event.
      @impl Phoenix.LiveView
      def handle_info({:step_event, _step, "theme:" <> name, params}, socket),
        do: handle_theme_event(name, params, socket)

      def handle_info({:step_event, step, event, data}, socket) do
        case TymeslotWeb.Themes.Shared.Journey.Runtime.handle_step_event(
               socket,
               step,
               event,
               data
             ) do
          :unhandled ->
            TymeslotWeb.Themes.Shared.StepEvents.log_ignored(socket.assigns, step, event)
            {:noreply, socket}

          reply ->
            reply
        end
      end

      # Must stay last: a public page cannot afford to raise on a message it
      # has no clause for. A theme has no hook here: `defoverridable` replaces
      # a function's clauses wholesale, so one theme-specific clause would
      # silently drop slot loading, calendar refresh and payment handling.
      def handle_info(message, socket) do
        case TymeslotWeb.Themes.Shared.InfoHandlers.route(message, socket) do
          :unhandled -> TymeslotWeb.Themes.Shared.InfoHandlers.handle_unexpected(socket, message)
          reply -> reply
        end
      end

      # The flow's `start_async/3` results, forwarded by the dispatcher: a
      # week view's week of slots is the only one.
      @impl Phoenix.LiveView
      def handle_async(name, result, socket) do
        case TymeslotWeb.Live.Scheduling.WeekSlots.handle_async(name, result, socket) do
          :unhandled -> {:noreply, socket}
          reply -> reply
        end
      end

      @impl Phoenix.LiveView
      def handle_event("toggle_language_dropdown", _params, socket),
        do: TymeslotWeb.Themes.Shared.EventHandlers.handle_toggle_language_dropdown(socket)

      def handle_event("close_language_dropdown", _params, socket),
        do: TymeslotWeb.Themes.Shared.EventHandlers.handle_close_language_dropdown(socket)

      def handle_event("change_locale", %{"locale" => locale}, socket),
        do:
          TymeslotWeb.Themes.Shared.EventHandlers.handle_change_locale(
            socket,
            locale,
            TymeslotWeb.Themes.Shared.PathHandlers
          )

      # Step navigation belongs to the flow, not to a theme: a clause of
      # `handle_theme_event/3` would be replaced wholesale by a theme's own
      # override of that hook.
      def handle_event("navigate_to_step", params, socket),
        do: TymeslotWeb.Themes.Shared.Journey.Runtime.navigate_to_step(socket, params)

      def handle_event("theme:" <> name, params, socket),
        do: handle_theme_event(name, params, socket)

      def handle_event(event, params, socket), do: handle_theme_event(event, params, socket)

      # Extension point. Override with multi-clause defps ending in a
      # catch-all clause that calls super/3, so an unknown name is logged.
      defp handle_theme_event(event, _params, socket) do
        TymeslotWeb.Themes.Shared.StepEvents.log_ignored(
          socket.assigns,
          socket.assigns[:current_state],
          event
        )

        {:noreply, socket}
      end

      defoverridable handle_theme_event: 3
    end
  end

  # The journey's literal for `__journey__/0`, after checking it: `steps:`
  # (today's five steps) becomes `Journey.classic/1` of its map. Its aliases
  # are resolved here, where they were checked (`qualify/2`).
  defp journey!(opts, caller) do
    case {Keyword.fetch(opts, :steps), Keyword.fetch(opts, :journey)} do
      {{:ok, steps}, :error} ->
        validate_steps!(steps)
        validate_step_components!(steps, caller)
        journey_module().build!(journey_module().classic(literal!(steps, caller)), caller)
        quote do: TymeslotWeb.Themes.Shared.Journey.classic(unquote(qualify(steps, caller)))

      {:error, {:ok, journey}} ->
        journey_module().build!(literal!(journey, caller), caller)
        qualify(journey, caller)

      {{:ok, _steps}, {:ok, _journey}} ->
        raise ArgumentError,
              "use SchedulingLive takes :steps (the classic journey) or :journey, not both"

      {:error, :error} ->
        raise ArgumentError,
              "use SchedulingLive needs :steps (the classic journey) or :journey"
    end
  end

  # `Journey`, named through a module atom returned at run time rather than an
  # alias: xref records an alias as a reference, and every theme's
  # compile-time edge to this module would then count everything `Journey`
  # reaches on its compile-connected graph. Only the macro calls it, while a
  # theme compiles.
  defp journey_module, do: :"Elixir.TymeslotWeb.Themes.Shared.Journey"

  # The journey's options as data, while the theme compiles: aliases expanded
  # as if inside a function (see `validate_step_components!/2` for why), the
  # rest literal. Walked by hand rather than evaluated, so nothing but data
  # can run here.
  defp literal!({:__aliases__, _meta, _parts} = alias_ast, caller),
    do: Macro.expand(alias_ast, %{caller | function: {:__journey__, 0}})

  defp literal!({:%{}, _meta, pairs}, caller),
    do: Map.new(pairs, fn {key, value} -> {literal!(key, caller), literal!(value, caller)} end)

  defp literal!({:{}, _meta, items}, caller),
    do: items |> Enum.map(&literal!(&1, caller)) |> List.to_tuple()

  defp literal!({left, right}, caller), do: {literal!(left, caller), literal!(right, caller)}
  defp literal!(list, caller) when is_list(list), do: Enum.map(list, &literal!(&1, caller))

  defp literal!(term, _caller) when is_atom(term) or is_number(term) or is_binary(term),
    do: term

  defp literal!(other, _caller) do
    raise ArgumentError,
          "use SchedulingLive expects its journey as literal data (atoms, lists, tuples, " <>
            "maps and module names), got: " <> Macro.to_string(other)
  end

  # The literal with each alias replaced by the module it names in the
  # theme, written in full and marked so no alias applies to it again: the
  # generated code adds aliases of its own (`use TymeslotWeb, :live_view`),
  # which must not change what the theme's journey names. A module name
  # stays a runtime reference, as an alias is.
  defp qualify(literal, caller) do
    Macro.prewalk(literal, fn
      {:__aliases__, meta, _parts} = alias_ast ->
        alias_ast |> literal!(caller) |> full_alias(meta)

      other ->
        other
    end)
  end

  # `alias: false` is how `quote` marks a name no alias may change; one
  # segment holding the whole module expands to that module.
  defp full_alias(module, meta) do
    case Atom.to_string(module) do
      "Elixir." <> _name -> {:__aliases__, Keyword.put(meta, :alias, false), [module]}
      _erlang -> module
    end
  end

  defp validate_steps!({:%{}, _meta, pairs}) do
    keys = Keyword.keys(pairs)

    case {@steps -- keys, keys -- @steps} do
      {[], []} ->
        :ok

      {[], unknown} ->
        raise ArgumentError,
              "use SchedulingLive got steps it does not know: #{inspect(unknown)}; " <>
                "the steps are #{inspect(@steps)}"

      {missing, _unknown} ->
        raise ArgumentError,
              "use SchedulingLive needs a component for every step; missing: #{inspect(missing)}"
    end
  end

  defp validate_steps!(other) do
    raise ArgumentError,
          "use SchedulingLive expects :steps as a literal map of step => component, got: " <>
            Macro.to_string(other)
  end

  # Checked here, while the theme compiles, rather than in an `@after_verify`
  # callback: an exception raised there crashes the compiler's checker process
  # instead of surfacing from `Code.compile_quoted/1`, so no test could see it.
  # The aliases are expanded as if inside a function, so the theme's `live.ex`
  # keeps a runtime dependency on its step components rather than a
  # compile-time one: the components import `StepEvents`, and a compile-time
  # edge to them would pull that chain into every theme's recompilation.
  defp validate_step_components!({:%{}, _meta, pairs}, caller) do
    Enum.each(pairs, fn {step, alias_ast} ->
      module = Macro.expand(alias_ast, %{caller | function: {:render, 1}})

      unless journey_module().live_component?(module) do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "use SchedulingLive needs a LiveComponent for step #{inspect(step)}, " <>
              "got #{inspect(module)}, which is not a loaded LiveComponent"
      end
    end)
  end
end

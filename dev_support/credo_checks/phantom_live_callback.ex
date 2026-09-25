defmodule CredoChecks.PhantomLiveCallback do
  @moduledoc """
  Flags callbacks in the LiveView stack that the framework never invokes.

  One callback currently qualifies: `handle_info/2` in a **LiveComponent**. A
  component has no process of its own; it runs inside the parent LiveView, and
  every message sent with `send(self(), …)` lands in the parent's mailbox. The
  component's clause is unreachable from the moment it is written, and
  `Phoenix.LiveComponent`'s own documentation says so outright: "note that
  components do not have a `c:Phoenix.LiveView.handle_info/2`".

  It does not raise, warn, or fail a test: the code simply sits there looking
  handled. The usual shape is a clause that once lived in the parent and was
  copied down into a component during a split, leaving two identical handlers
  of which only one runs.

  ## Why `terminate/2` is not flagged

  `terminate/2` in a LiveView looks like a member of this family and is not.
  LiveView's own documentation scopes the caveat to crashes: "In case of
  errors, this callback is only invoked if the LiveView is trapping exits."
  An ordinary disconnect is not an error. Closing the tab, leaving the
  channel, a draining node and a parent exit all return `{:stop, {:shutdown,
  reason}, state}` from the channel's own `handle_info/2`, and a GenServer
  stopping itself that way runs `terminate/2` whether or not it traps exits.
  The callback's `reason` typespec admits `{:shutdown, :left | :closed}` for
  exactly that reason.

  So cleanup written in `terminate/2` does run on a graceful disconnect. What
  it does not survive is an abnormal exit, which makes the callback a poor
  place for cleanup that must happen, but not a phantom. Flagging it would
  mean telling working code it is dead. Where cleanup has to hold through a
  crash too, monitor the LiveView from a separate process and act on the
  `:DOWN` message.

  ## What to do instead

  For a component that needs to react to a message, have the **parent**
  LiveView handle it and pass the result down through `update/2`, or send the
  component an update directly with `Phoenix.LiveView.send_update/3`.

  ## Examples

      # Bad — never runs; the message reaches the parent LiveView instead
      defmodule MyAppWeb.ScheduleSettingsComponent do
        use MyAppWeb, :live_component

        def handle_info({:reload, id}, socket), do: {:noreply, reload(socket, id)}
      end

      # Good — the parent handles it and pushes the result into the component
      defmodule MyAppWeb.DashboardLive do
        use MyAppWeb, :live_view

        def handle_info({:reload, id}, socket) do
          send_update(MyAppWeb.ScheduleSettingsComponent, id: "settings", reload: id)
          {:noreply, socket}
        end
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      This callback is never invoked in this kind of module.

      handle_info/2 in a LiveComponent is unreachable: components share the
      parent LiveView's process, so the message goes to the parent. Handle it
      there and use send_update/3, or have the parent pass the result down.
      """
    ]

  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  # {module kind, callback name, arity}
  #
  # `{:live_view, :terminate, 2}` does not belong here: a graceful disconnect
  # stops the channel with `{:stop, {:shutdown, reason}, state}`, which runs
  # `terminate/2` regardless of trapping. See the moduledoc. `module_kind/1`
  # still resolves `:live_view` so that a genuine LiveView-only phantom can be
  # added to this list later.
  @phantom_callbacks [
    {:live_component, :handle_info, 2}
  ]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # ---------------------------------------------------------------------------
  # Traversal
  # ---------------------------------------------------------------------------

  defp traverse({:defmodule, _meta, [_name, [do: {:__block__, _bm, body}]]} = ast, issues, meta) do
    {ast, check_module(body, meta) ++ issues}
  end

  defp traverse({:defmodule, _meta, [_name, [do: single]]} = ast, issues, meta)
       when not is_list(single) do
    {ast, check_module([single], meta) ++ issues}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp check_module(body, issue_meta) do
    case module_kind(body) do
      nil ->
        []

      kind ->
        @phantom_callbacks
        |> Enum.filter(fn {callback_kind, _name, _arity} -> callback_kind == kind end)
        |> Enum.flat_map(fn {_kind, name, arity} ->
          body
          |> definitions(name, arity)
          |> Enum.map(&build_issue(issue_meta, &1, kind, name, arity))
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Module kind
  # ---------------------------------------------------------------------------

  # Only the module's own `use` decides its kind. A module that injects a
  # callback into someone else through `quote` (the theme handler mixins) has
  # no `use` of its own and is left alone, which is correct: the callback is
  # not phantom there, it lands in whichever LiveView does the injecting.
  defp module_kind(body) do
    Enum.find_value(body, fn
      {:use, _meta, [{:__aliases__, _am, segments}, kind]}
      when kind in [:live_view, :live_component] ->
        if web_module?(segments), do: kind

      {:use, _meta, [{:__aliases__, _am, segments} | _opts]} ->
        phoenix_kind(segments)

      _other ->
        nil
    end)
  end

  # `use TymeslotWeb, :live_view` — accept any `*Web` module so the check works
  # unchanged in the overlay repo (`TymeslotSaasWeb`).
  defp web_module?(segments) do
    segments |> List.last() |> to_string() |> String.ends_with?("Web")
  end

  defp phoenix_kind([:Phoenix, :LiveView]), do: :live_view
  defp phoenix_kind([:Phoenix, :LiveComponent]), do: :live_component
  defp phoenix_kind(_segments), do: nil

  # ---------------------------------------------------------------------------
  # Definitions
  # ---------------------------------------------------------------------------

  # Public definitions only: a private `handle_info/2` helper is an ordinary
  # function that happens to share the name, not a callback.
  defp definitions(body, name, arity) do
    body
    |> Enum.filter(&match?({:def, _meta, [_head, _body]}, &1))
    |> Enum.filter(fn {:def, _meta, [head, _body]} -> head_matches?(head, name, arity) end)
    |> Enum.map(fn {:def, meta, _args} -> meta[:line] end)
  end

  defp head_matches?({:when, _meta, [head | _guards]}, name, arity),
    do: head_matches?(head, name, arity)

  defp head_matches?({name, _meta, args}, name, arity) when is_list(args),
    do: length(args) == arity

  defp head_matches?(_head, _name, _arity), do: false

  # ---------------------------------------------------------------------------
  # Issues
  # ---------------------------------------------------------------------------

  defp build_issue(issue_meta, line_no, :live_component, name, arity) do
    format_issue(issue_meta,
      message:
        "`#{name}/#{arity}` is never called in a LiveComponent: components run inside the " <>
          "parent LiveView's process, so the message reaches the parent's mailbox. Handle it " <>
          "in the parent and use `send_update/3`.",
      line_no: line_no,
      trigger: "#{name}"
    )
  end
end

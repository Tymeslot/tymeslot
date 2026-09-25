defmodule CredoChecks.PutFlashInLiveComponent do
  @moduledoc """
  Flags a bare `put_flash/2,3` called inside a LiveComponent.

  `Phoenix.LiveView.put_flash/3` only mutates the flash on the socket it
  receives — inside a `Phoenix.LiveComponent` that is the component's own
  socket, never the parent LiveView's. The component is never rendered with
  the flash group, so the message is silently dropped: no crash, no warning,
  just a flash that never appears. The project already hit this and built
  `TymeslotWeb.Live.Shared.Flash` (`lib/tymeslot_web/live/shared/flash.ex`) to
  fix it: its helpers `send/2` a `{:flash, {type, message}}` message to the
  current process, which the parent LiveView forwards to the real flash via
  `handle_info/2`.

  `lib/tymeslot_web/live/dashboard/payments_settings_component.ex:17-19`
  documents the same precedent in its own moduledoc: "Flash messages are
  forwarded to the parent LiveView via `Flash` (a bare `put_flash/3` inside a
  LiveComponent never reaches the rendered flash group)."

  ## What to do instead

  Call `Flash.put_flash/3` (pipe-friendly, returns the socket unchanged) or
  one of the fire-and-forget helpers `Flash.error/1` / `Flash.info/1` /
  `Flash.warning/1` instead of `put_flash/2,3` directly.

  ## Examples

      # Bad — silently dropped, the component's socket never renders the flash group
      defmodule TymeslotWeb.Dashboard.PaymentsSettingsComponent do
        use TymeslotWeb, :live_component

        def handle_event("save", _params, socket) do
          {:noreply, put_flash(socket, :error, "Could not save")}
        end
      end

      # Bad — piped, and module-qualified, are just as silent
      socket |> put_flash(:info, "Saved!")
      LiveView.put_flash(socket, :error, "Payment not found.")

      # Good — forwarded to the parent LiveView, which owns the flash
      defmodule TymeslotWeb.Dashboard.PaymentsSettingsComponent do
        use TymeslotWeb, :live_component

        alias TymeslotWeb.Live.Shared.Flash

        def handle_event("save", _params, socket) do
          {:noreply, socket |> assign(:saving, false) |> Flash.put_flash(:error, "Could not save")}
        end
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      `put_flash/2,3` mutates the socket it is given. Inside a LiveComponent
      that is the component's own socket, which is never rendered with the
      flash group, so the message never appears.

      Replace it with `TymeslotWeb.Live.Shared.Flash.put_flash/3` (or the
      `Flash.error/1` / `Flash.info/1` / `Flash.warning/1` helpers), which
      forward the message to the parent LiveView instead.
      """
    ]

  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

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
    if live_component?(body) do
      {_ast, issues} = Macro.prewalk(body, [], &collect_put_flash(&1, &2, issue_meta))
      issues
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Module kind
  # ---------------------------------------------------------------------------

  # Only the module's own `use` decides its kind, matching the `use` shapes
  # `CredoChecks.PhantomLiveCallback` recognises for a LiveComponent.
  defp live_component?(body) do
    Enum.any?(body, &live_component_use?/1)
  end

  defp live_component_use?({:use, _meta, [{:__aliases__, _am, segments}, :live_component]}) do
    web_module?(segments)
  end

  defp live_component_use?(
         {:use, _meta, [{:__aliases__, _am, [:Phoenix, :LiveComponent]} | _opts]}
       ) do
    true
  end

  defp live_component_use?(_other), do: false

  # `use TymeslotWeb, :live_component` — accept any `*Web` module so the check
  # works unchanged in the overlay repo (`TymeslotSaasWeb`).
  defp web_module?(segments) do
    segments |> List.last() |> to_string() |> String.ends_with?("Web")
  end

  # ---------------------------------------------------------------------------
  # put_flash calls
  # ---------------------------------------------------------------------------

  # Bare or piped: `put_flash(socket, :level, msg)` and `socket |> put_flash(:level, msg)`
  # parse to the same node shape, arity 3 and 2 respectively.
  defp collect_put_flash({:put_flash, meta, args} = node, issues, issue_meta)
       when is_list(args) and length(args) in [2, 3] do
    {node, [build_issue(issue_meta, meta[:line]) | issues]}
  end

  # Module-qualified: `LiveView.put_flash(...)`, `Phoenix.LiveView.put_flash(...)`, etc.
  # Skipped when the alias's last segment is `Flash` — the sanctioned wrapper.
  defp collect_put_flash(
         {{:., _dot_meta, [{:__aliases__, _am, mods}, :put_flash]}, meta, args} = node,
         issues,
         issue_meta
       )
       when is_list(args) and length(args) in [2, 3] do
    if List.last(mods) == :Flash do
      {node, issues}
    else
      {node, [build_issue(issue_meta, meta[:line]) | issues]}
    end
  end

  defp collect_put_flash(node, issues, _issue_meta), do: {node, issues}

  # ---------------------------------------------------------------------------
  # Issues
  # ---------------------------------------------------------------------------

  defp build_issue(issue_meta, line_no) do
    format_issue(issue_meta,
      message:
        "`put_flash` writes onto the LiveComponent's own socket, which is never rendered " <>
          "with the flash group, so the message never appears. Use " <>
          "`TymeslotWeb.Live.Shared.Flash.put_flash/3` (or `Flash.error/1` / `Flash.info/1`) " <>
          "to forward it to the parent LiveView instead.",
      line_no: line_no,
      trigger: "put_flash"
    )
  end
end

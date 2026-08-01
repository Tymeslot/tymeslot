defmodule TymeslotWeb.Components.CoreComponents.Flash do
  @moduledoc "Flash components extracted from CoreComponents."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  # Phoenix modules
  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Feedback

  # ========== FLASH MESSAGES ==========

  @doc """
  Renders a flash notice with modern branding.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} title="Success!">Operation completed successfully</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil, doc: "optional title for the flash message"
  attr :kind, :atom, values: [:info, :error, :warning], doc: "used for styling and flash lookup"
  attr :autoshow, :boolean, default: true, doc: "whether to auto show the flash on mount"
  attr :close, :boolean, default: true, doc: "whether the flash can be closed"
  attr :hook, :string, default: "Flash", doc: "the LiveView hook name to attach"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  slot :inner_block, doc: "the optional inner block that renders the flash message"

  @spec flash(map()) :: Phoenix.LiveView.Rendered.t()
  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-hook={@hook}
      phx-mounted={
        @autoshow &&
          JS.show(
            to: "##{@id}",
            transition:
              {"transition-all duration-500 ease-out transform", "opacity-0 translate-y-4 scale-95",
               "opacity-100 translate-y-0 scale-100"}
          )
      }
      phx-click={@close && JS.push("lv:clear-flash", value: %{key: @kind}) |> hide_flash(@id)}
      role="alert"
      class={[
        "w-80 sm:w-96 rounded-2xl p-5 shadow-2xl relative overflow-hidden border-2",
        "transition-all duration-300 hover:scale-[1.02] cursor-pointer",
        flash_variant(@kind)
      ]}
      {@rest}
    >
      <div class="relative z-10 flex items-start gap-4">
        <div class={[
          "shrink-0 w-10 h-10 rounded-xl flex items-center justify-center shadow-sm border",
          icon_bg_color(@kind)
        ]}>
          <svg :if={@kind == :info} class="h-6 w-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
          <svg :if={@kind == :error} class="h-6 w-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z" />
          </svg>
          <svg :if={@kind == :warning} class="h-6 w-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z" />
          </svg>
        </div>

        <div class="flex-1 min-w-0">
          <p :if={@title} class="text-sm font-black uppercase tracking-wider mb-1">
            {@title}
          </p>
          <p class="text-sm font-bold leading-relaxed">
            {msg}
          </p>
        </div>

        <button
          :if={@close}
          type="button"
          class="shrink-0 text-current opacity-40 hover:opacity-100 transition-opacity"
          aria-label={dgettext("common", "Close")}
        >
          <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
      </div>
    </div>
    """
  end

  # Helper function for flash styling variants
  defp flash_variant(:info) do
    "bg-white border-turquoise-100 text-tymeslot-900 shadow-turquoise-500/10"
  end

  defp flash_variant(:error) do
    "bg-red-50 border-red-100 text-red-900 shadow-red-500/10"
  end

  defp flash_variant(:warning) do
    "bg-amber-50 border-amber-100 text-amber-900 shadow-amber-500/10"
  end

  defp flash_variant(_arg), do: flash_variant(:info)

  # Helper function for icon backgrounds
  defp icon_bg_color(:info), do: "bg-turquoise-50 border-turquoise-100 text-turquoise-600"
  defp icon_bg_color(:error), do: "bg-white border-red-100 text-red-500"
  defp icon_bg_color(:warning), do: "bg-white border-amber-100 text-amber-600"
  defp icon_bg_color(_arg), do: icon_bg_color(:info)

  # Helper function to hide flash with animation
  defp hide_flash(js, id) do
    JS.hide(js,
      to: "##{id}",
      transition:
        {"transition-all duration-300 ease-in transform", "opacity-100 translate-y-0 scale-100",
         "opacity-0 translate-y-4 scale-95"}
    )
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="fixed top-4 right-4 z-[10050] flex flex-col gap-3 pointer-events-none">
      <div class="pointer-events-auto">
        <.flash kind={:info} flash={@flash} id={"#{@id}-info"} />
      </div>
      <div class="pointer-events-auto">
        <.flash kind={:error} flash={@flash} id={"#{@id}-error"} />
      </div>
      <div class="pointer-events-auto">
        <.flash kind={:warning} flash={@flash} id={"#{@id}-warning"} />
      </div>

      <div class="pointer-events-auto">
        <.flash
          id={"#{@id}-disconnected"}
          kind={:error}
          title={dgettext("common", "Connection Lost")}
          close={false}
          autoshow={false}
          hook="ConnectionStatus"
          phx-disconnected={JS.dispatch("tymeslot:lv-disconnected", to: "##{@id}-disconnected")}
          phx-connected={JS.dispatch("tymeslot:lv-connected", to: "##{@id}-disconnected")}
          style="display: none;"
        >
          {dgettext("common", "Attempting to reconnect")}
          <Feedback.spinner class="ml-1 w-3 h-3 inline-block" />
        </.flash>
      </div>
    </div>
    """
  end
end

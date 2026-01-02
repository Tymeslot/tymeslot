defmodule TymeslotWeb.Components.CoreComponents.Flash do
  @moduledoc "Flash components extracted from CoreComponents."
  use Phoenix.Component

  # Phoenix modules
  alias Phoenix.LiveView.JS

  # ========== FLASH MESSAGES ==========

  @doc """
  Renders a flash notice with modern glassmorphism styling.

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
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  slot :inner_block, doc: "the optional inner block that renders the flash message"
  @spec flash(map()) :: Phoenix.LiveView.Rendered.t()
  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-hook="Flash"
      phx-mounted={
        @autoshow &&
          JS.show(
            to: "##{@id}",
            transition:
              {"transition-all duration-300 ease-out transform", "opacity-0 translate-x-8",
               "opacity-100 translate-x-0"}
          )
      }
      phx-click={@close && JS.push("lv:clear-flash", value: %{key: @kind}) |> hide_flash(@id)}
      role="alert"
      class={[
        "w-80 sm:w-96 rounded-2xl p-4 shadow-2xl relative overflow-hidden",
        "backdrop-blur-md border transition-all duration-300",
        "hover:scale-[1.02] hover:shadow-3xl",
        flash_variant(@kind)
      ]}
      {@rest}
    >
      <div class="absolute inset-0 bg-gradient-to-r opacity-30 pointer-events-none" aria-hidden="true">
      </div>
      <div
        class="absolute inset-0 bg-gradient-to-b from-white/10 to-transparent pointer-events-none"
        aria-hidden="true"
      >
      </div>

      <div class="relative z-10 flex items-start gap-3">
        <div class={[
          "flex-shrink-0 rounded-full p-2 transition-transform duration-300",
          "bg-white/20 backdrop-blur-sm shadow-inner hover:scale-110",
          icon_color(@kind)
        ]}>
          <svg :if={@kind == :info} class="h-5 w-5" fill="currentColor" viewBox="0 0 20 20">
            <path
              fill-rule="evenodd"
              d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
              clip-rule="evenodd"
            />
          </svg>
          <svg :if={@kind == :error} class="h-5 w-5" fill="currentColor" viewBox="0 0 20 20">
            <path
              fill-rule="evenodd"
              d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z"
              clip-rule="evenodd"
            />
          </svg>
          <svg :if={@kind == :warning} class="h-5 w-5" fill="currentColor" viewBox="0 0 20 20">
            <path
              fill-rule="evenodd"
              d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
              clip-rule="evenodd"
            />
          </svg>
        </div>

        <div class="flex-1 min-w-0">
          <p :if={@title} class="text-sm font-bold mb-1">
            {@title}
          </p>
          <p class="text-sm leading-5 break-words">
            {msg}
          </p>
        </div>

        <button
          :if={@close}
          type="button"
          class="flex-shrink-0 group transition-transform duration-300 hover:scale-110 -m-1 p-1"
          aria-label="Close notification"
        >
          <svg
            class="h-5 w-5 opacity-70 transition-opacity group-hover:opacity-100"
            fill="currentColor"
            viewBox="0 0 20 20"
          >
            <path
              fill-rule="evenodd"
              d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z"
              clip-rule="evenodd"
            />
          </svg>
        </button>
      </div>
    </div>
    """
  end

  # Helper function for flash styling variants
  defp flash_variant(:info) do
    [
      "bg-gradient-to-br from-blue-500/90 to-indigo-500/90 text-white",
      "border-blue-400/50 shadow-blue-500/25"
    ]
  end

  defp flash_variant(:error) do
    [
      "bg-gradient-to-br from-rose-500/90 to-pink-500/90 text-white",
      "border-rose-400/50 shadow-rose-500/25"
    ]
  end

  defp flash_variant(:warning) do
    [
      "bg-gradient-to-br from-amber-500/90 to-orange-500/90 text-white",
      "border-amber-400/50 shadow-amber-500/25"
    ]
  end

  defp flash_variant(_), do: flash_variant(:info)

  # Helper function for icon colors
  defp icon_color(:info), do: "text-blue-100"
  defp icon_color(:error), do: "text-rose-100"
  defp icon_color(:warning), do: "text-amber-100"
  defp icon_color(_), do: "text-blue-100"

  # Helper function to hide flash with animation
  defp hide_flash(js, id) do
    JS.hide(js,
      to: "##{id}",
      transition:
        {"transition-all duration-300 ease-in transform", "opacity-100 translate-x-0",
         "opacity-0 translate-x-8"}
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
          title="Connection Lost"
          close={false}
          autoshow={false}
          phx-disconnected={
            JS.show(
              to: "##{@id}-disconnected",
              transition:
                {"transition-all duration-300 ease-out transform", "opacity-0 translate-x-8",
                 "opacity-100 translate-x-0"}
            )
          }
          phx-connected={
            JS.hide(
              to: "##{@id}-disconnected",
              transition:
                {"transition-all duration-300 ease-in transform", "opacity-100 translate-x-0",
                 "opacity-0 translate-x-8"}
            )
          }
          style="display: none;"
        >
          Attempting to reconnect
          <svg class="ml-1 w-3 h-3 animate-spin inline-block" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
            </circle>
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            >
            </path>
          </svg>
        </.flash>
      </div>
    </div>
    """
  end
end

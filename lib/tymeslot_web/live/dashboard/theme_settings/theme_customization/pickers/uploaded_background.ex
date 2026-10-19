defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.UploadedBackground do
  @moduledoc """
  The organiser's stored background upload of one kind (image or video),
  in the background's image and video pickers.

  An uploaded image and an uploaded video both stay stored whatever the
  background shows, so each picker offers its upload as a choice of its
  own: choosing it shows the upload again without a new one
  (`theme:set_option` with the kind and `"custom"`), and Remove deletes it
  (the field `"remove"`; a background that was showing it falls back to the
  theme's default). Nothing is drawn when no upload of the kind is stored.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ThemeCustomizations.Options.Background

  attr :kind, :atom, required: true, values: [:image, :video]
  attr :option, :any, required: true, doc: "the background group's key"
  attr :customization, :map, required: true
  attr :myself, :any, required: true

  @spec uploaded_background(map()) :: Phoenix.LiveView.Rendered.t()
  def uploaded_background(assigns) do
    settings = assigns.customization.settings
    path = settings["background_#{assigns.kind}_path"]

    assigns =
      assign(assigns,
        url: path && Background.upload_url(path),
        shown?: Background.showing_upload?(settings, assigns.kind),
        kind_name: Atom.to_string(assigns.kind)
      )

    ~H"""
    <div :if={@url} class="space-y-4" data-testid={"uploaded-#{@kind_name}"}>
      <p class="text-token-sm font-black text-tymeslot-400 uppercase tracking-widest">
        {dgettext("dashboard_appearance", "Your upload")}
      </p>
      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6 items-start">
        <button
          type="button"
          class={[
            "relative flex flex-col rounded-token-2xl overflow-hidden border-4 transition-all duration-500",
            if(@shown?,
              do: "border-turquoise-400 shadow-2xl shadow-turquoise-500/20",
              else:
                "border-white hover:border-turquoise-200 hover:shadow-xl hover:shadow-tymeslot-200/50"
            )
          ]}
          aria-pressed={to_string(@shown?)}
          phx-click="theme:set_option"
          phx-value-option={@option}
          phx-value-field={@kind_name}
          phx-value-choice="custom"
          phx-target={@myself}
          data-testid={"show-uploaded-#{@kind_name}"}
        >
          <div class="aspect-video relative overflow-hidden bg-tymeslot-900">
            <img
              :if={@kind == :image}
              src={@url}
              alt=""
              class="w-full h-full object-cover"
            />
            <video
              :if={@kind == :video}
              src={@url}
              class="w-full h-full object-cover"
              muted
              playsinline
              preload="metadata"
            ></video>
            <div
              :if={@shown?}
              class="absolute top-3 right-3 w-8 h-8 bg-turquoise-500 text-white rounded-token-full flex items-center justify-center shadow-lg"
            >
              <.icon name="hero-check" class="w-5 h-5" />
            </div>
          </div>
          <div class={["p-5 text-left", if(@shown?, do: "bg-turquoise-50", else: "bg-white")]}>
            <p class="text-token-base font-black text-tymeslot-900 tracking-tight">
              {if @kind == :image,
                do: dgettext("dashboard_appearance", "Your uploaded image"),
                else: dgettext("dashboard_appearance", "Your uploaded video")}
            </p>
            <p class="text-token-xs text-tymeslot-500 font-bold mt-1">
              {dgettext("dashboard_appearance", "Kept until you replace or remove it.")}
            </p>
          </div>
        </button>

        <.action_button
          variant={:danger_soft}
          icon="hero-trash-mini"
          class="self-center sm:self-start"
          phx-click="theme:set_option"
          phx-value-option={@option}
          phx-value-field="remove"
          phx-value-choice={@kind_name}
          phx-target={@myself}
          data-testid={"remove-uploaded-#{@kind_name}"}
        >
          {if @kind == :image,
            do: dgettext("dashboard_appearance", "Remove image"),
            else: dgettext("dashboard_appearance", "Remove video")}
        </.action_button>
      </div>
    </div>
    """
  end
end

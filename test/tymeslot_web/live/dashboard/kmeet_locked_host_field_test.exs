defmodule TymeslotWeb.Dashboard.KmeetLockedHostFieldTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :video
  @moduletag :integrations

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Integrations.Video.SharedFormComponents

  test "reads the host from a focusable field linked to its tooltip and help" do
    html =
      render_component(&SharedFormComponents.locked_host_field/1, %{
        id: "kmeet-host",
        value: "kmeet.infomaniak.com",
        tooltip: "kMeet always uses this address, which cannot be changed.",
        helper_text: "Every booking gets its own room."
      })

    doc = Floki.parse_fragment!(html)

    input = Floki.find(doc, "input#kmeet-host")

    assert Floki.attribute(input, "readonly") != []
    assert Floki.attribute(input, "disabled") == []
    assert Floki.attribute(input, "aria-describedby") == ["kmeet-host-tooltip kmeet-host-help"]

    assert doc |> Floki.find("#kmeet-host-tooltip[role='tooltip']") |> Floki.text() =~
             "cannot be changed"
  end
end

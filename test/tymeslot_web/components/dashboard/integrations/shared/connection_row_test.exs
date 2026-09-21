defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionRowTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :integrations
  @moduletag :components
  @moduletag :unit

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionRow

  describe "server_label/1" do
    # The defect this guards: two self-hosted instances behind one host — the
    # ordinary shape of a staging server or a reverse proxy — used to render as
    # the same line, because only the hostname was shown.
    test "keeps the port and the path, so two instances on one host differ" do
      assert ConnectionRow.server_label("http://localhost:8080/nextcloud") ==
               "localhost:8080/nextcloud"

      assert ConnectionRow.server_label("http://localhost:8081/nc") == "localhost:8081/nc"
    end

    test "drops the scheme and a port the scheme implies" do
      assert ConnectionRow.server_label("https://cloud.example.com") == "cloud.example.com"
      assert ConnectionRow.server_label("http://cloud.example.com:80") == "cloud.example.com"
    end

    # Not every provider rejects a base URL carrying credentials — MiroTalk's
    # validation strips the userinfo for its SSRF guard rather than refusing the
    # URL — so a stored password must be dropped here rather than printed.
    test "never renders credentials embedded in the URL" do
      label = ConnectionRow.server_label("https://admin:hunter2@meet.example.com:8443/room")

      assert label == "meet.example.com:8443/room"
      refute label =~ "hunter2"
      refute label =~ "admin"
    end

    test "returns nil for a missing or unparseable server" do
      assert ConnectionRow.server_label(nil) == nil
      assert ConnectionRow.server_label("") == nil
      assert ConnectionRow.server_label("not a url") == nil
    end
  end

  describe "connection_row/1" do
    # The summary is hard-truncated to one line, so the full value has to stay
    # reachable once a longer server string overflows it.
    test "exposes the whole summary as the hover title" do
      html = render_row(summary: "organiser@example.com · localhost:8080/nextcloud")

      assert html =~ ~s(title="organiser@example.com · localhost:8080/nextcloud")
    end

    test "omits the title attribute when there is no summary" do
      refute render_row(summary: "") =~ ~s(title="")
    end
  end

  defp render_row(overrides) do
    assigns =
      Enum.into(overrides, %{
        id: "42",
        icon: "mirotalk",
        icon_type: :video,
        title: "Team Room",
        summary: "localhost:8080/nextcloud",
        status: {:ok, "Healthy"},
        active?: true,
        toggle_event: "toggle_integration",
        myself: nil
      })

    render_component(&ConnectionRow.connection_row/1, assigns)
  end
end

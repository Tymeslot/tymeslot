defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionLabelsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :integrations
  @moduletag :components
  @moduletag :unit

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionLabels

  describe "server_label/1" do
    # The defect this guards: two self-hosted instances behind one host (the
    # ordinary shape of a staging server or a reverse proxy) used to render as
    # the same line, because only the hostname was shown.
    test "keeps the port and the path, so two instances on one host differ" do
      assert ConnectionLabels.server_label("http://localhost:8080/nextcloud") ==
               "localhost:8080/nextcloud"

      assert ConnectionLabels.server_label("http://localhost:8081/nc") == "localhost:8081/nc"
    end

    test "drops the scheme and a port the scheme implies" do
      assert ConnectionLabels.server_label("https://cloud.example.com") == "cloud.example.com"
      assert ConnectionLabels.server_label("http://cloud.example.com:80") == "cloud.example.com"
    end

    # Not every provider rejects a base URL carrying credentials (MiroTalk's
    # validation strips the userinfo for its SSRF guard rather than refusing the
    # URL), so a stored password must be dropped here rather than printed.
    test "never renders credentials embedded in the URL" do
      label = ConnectionLabels.server_label("https://admin:hunter2@meet.example.com:8443/room")

      assert label == "meet.example.com:8443/room"
      refute label =~ "hunter2"
      refute label =~ "admin"
    end

    test "returns nil for a missing or unparseable server" do
      assert ConnectionLabels.server_label(nil) == nil
      assert ConnectionLabels.server_label("") == nil
      assert ConnectionLabels.server_label("not a url") == nil
    end
  end
end

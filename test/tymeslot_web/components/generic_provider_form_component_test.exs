defmodule TymeslotWeb.Integrations.Providers.GenericProviderFormComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Integrations.Providers.GenericProviderFormComponent

  test "renders form fields based on schema" do
    schema = [
      {:api_key, %{type: :string, label: "API Key"}},
      {:is_active, %{type: :boolean}},
      {:start_date, %{type: :datetime}}
    ]

    html = render_component(GenericProviderFormComponent, id: "test-form", schema: schema)

    assert html =~ "API Key"
    # Default label from helper
    assert html =~ "Is active"
    assert html =~ "type=\"text\""
    assert html =~ "type=\"checkbox\""
    assert html =~ "type=\"datetime-local\""
    assert html =~ "Save"
  end

  test "renders fallback for unknown types" do
    schema = [{:custom, %{type: :unknown}}]
    html = render_component(GenericProviderFormComponent, id: "test-form", schema: schema)
    assert html =~ "type=\"text\""
  end
end

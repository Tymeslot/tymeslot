defmodule TymeslotWeb.ErrorJSONTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true

  alias TymeslotWeb.ErrorJSON

  test "renders 404" do
  @moduletag :utils
    assert ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end

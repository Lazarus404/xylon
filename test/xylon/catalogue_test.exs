defmodule Xylon.CatalogueTest do
  use ExUnit.Case, async: false

  setup do
    Xylon.Catalogue.reset!()
    :ok
  end

  test "attach registers backend id" do
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    assert {:ok, Xylon.Backend.Echo} = Xylon.Catalogue.fetch(:echo)
  end

  test "attach rejects unknown module without id/0" do
    assert {:error, :invalid_backend} = Xylon.attach(String)
  end
end

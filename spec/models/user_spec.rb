require 'rails_helper'

RSpec.describe User, type: :model do
  it "ユーザー登録できる" do
    expect { create(:user) }.to change { User.count }.by(1)
  end
end

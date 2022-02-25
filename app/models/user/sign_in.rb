# == Schema Information
# Schema version: 20220225094330
#
# Table name: user_sign_ins
#
#  id         :bigint           not null, primary key
#  user_id    :bigint
#  ip         :inet
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

# Record medadata about User sign in activity
class User::SignIn < ApplicationRecord
  default_scope { order(created_at: :desc) }

  belongs_to :user, inverse_of: :sign_ins

  before_create :create?

  def self.purge
    where('created_at < ?', retention_days.days.ago).destroy_all
  end

  def self.retain_signins?
    retention_days >= 1
  end

  def self.retention_days
    AlaveteliConfiguration.user_sign_in_activity_retention_days
  end

  private

  def create?
    throw :abort unless self.class.retain_signins?
  end
end

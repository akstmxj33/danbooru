class ForumTopic < ApplicationRecord
  CATEGORIES = {
    0 => "General",
    1 => "Tags",
    2 => "Bugs & Features"
  }

  MIN_LEVELS = {
    None: 0,
    Moderator: User::Levels::MODERATOR,
    Admin: User::Levels::ADMIN
  }

  belongs_to :creator, class_name: "User"
  belongs_to_updater
  has_many :posts, -> {order("forum_posts.id asc")}, :class_name => "ForumPost", :foreign_key => "topic_id", :dependent => :destroy
  has_many :forum_topic_visits
  has_many :moderation_reports, through: :posts
  has_one :original_post, -> {order("forum_posts.id asc")}, class_name: "ForumPost", foreign_key: "topic_id", inverse_of: :topic

  before_validation :initialize_is_deleted, :on => :create
  validates_presence_of :title
  validates_associated :original_post
  validates_inclusion_of :category_id, :in => CATEGORIES.keys
  validates_inclusion_of :min_level, :in => MIN_LEVELS.values
  validates :title, :length => {:maximum => 255}
  accepts_nested_attributes_for :original_post
  after_update :update_orignal_post
  after_save(:if => ->(rec) {rec.is_locked? && rec.saved_change_to_is_locked?}) do |rec|
    ModAction.log("locked forum topic ##{id} (title: #{title})", :forum_topic_lock)
  end

  module CategoryMethods
    extend ActiveSupport::Concern

    module ClassMethods
      def categories
        CATEGORIES.values
      end

      def reverse_category_mapping
        @reverse_category_mapping ||= CATEGORIES.invert
      end
    end

    def category_name
      CATEGORIES[category_id]
    end
  end

  module SearchMethods
    def active
      where(is_deleted: false)
    end

    def permitted
      where("min_level <= ?", CurrentUser.level)
    end

    def read_by_user(user)
      return none if user.last_forum_read_at.nil? || user.last_forum_read_at < '2000-01-01'

      read_topics = user.visited_forum_topics.where("forum_topic_visits.last_read_at >= forum_topics.updated_at")
      old_topics = where("? >= forum_topics.updated_at", user.last_forum_read_at)

      where(id: read_topics).or(where(id: old_topics))
    end

    def sticky_first
      order(is_sticky: :desc, updated_at: :desc)
    end

    def default_order
      order(updated_at: :desc)
    end

    def search(params)
      q = super
      q = q.permitted
      q = q.search_attributes(params, :creator, :updater, :is_sticky, :is_locked, :is_deleted, :category_id, :title, :response_count)
      q = q.text_attribute_matches(:title, params[:title_matches], index_column: :text_index)

      if params[:mod_only].present?
        q = q.where("min_level >= ?", MIN_LEVELS[:Moderator])
      end

      case params[:order]
      when "sticky"
        q = q.sticky_first
      else
        q = q.apply_default_order(params)
      end

      unless params[:is_deleted].present?
        q = q.active
      end

      q
    end
  end

  module VisitMethods
    def mark_as_read!(user = CurrentUser.user)
      return if user.is_anonymous?

      match = ForumTopicVisit.where(:user_id => user.id, :forum_topic_id => id).first
      if match
        match.update_attribute(:last_read_at, updated_at)
      else
        ForumTopicVisit.create(:user_id => user.id, :forum_topic_id => id, :last_read_at => updated_at)
      end

      has_unread_topics =
        ForumTopic
        .permitted
        .active
        .where("forum_topics.updated_at >= ?", user.last_forum_read_at)
        .joins("left join forum_topic_visits on (forum_topic_visits.forum_topic_id = forum_topics.id and forum_topic_visits.user_id = #{user.id})")
        .where("(forum_topic_visits.id is null or forum_topic_visits.last_read_at < forum_topics.updated_at)")
        .exists?

      unless has_unread_topics
        user.update_attribute(:last_forum_read_at, Time.now)
        ForumTopicVisit.prune!(user)
      end
    end
  end

  extend SearchMethods
  include CategoryMethods
  include VisitMethods

  def editable_by?(user)
    (creator_id == user.id || user.is_moderator?) && visible?(user)
  end

  def visible?(user)
    user.level >= min_level
  end

  def create_mod_action_for_delete
    ModAction.log("deleted forum topic ##{id} (title: #{title})", :forum_topic_delete)
  end

  def create_mod_action_for_undelete
    ModAction.log("undeleted forum topic ##{id} (title: #{title})", :forum_topic_undelete)
  end

  def initialize_is_deleted
    self.is_deleted = false if is_deleted.nil?
  end

  def page_for(post_id)
    (posts.where("id < ?", post_id).count / Danbooru.config.posts_per_page.to_f).ceil
  end

  def last_page
    (response_count / Danbooru.config.posts_per_page.to_f).ceil
  end

  def delete!
    update(is_deleted: true)
  end

  def undelete!
    update(is_deleted: false)
  end

  def update_orignal_post
    original_post&.update_columns(:updater_id => updater.id, :updated_at => Time.now)
  end

  def viewable_moderation_reports
    CurrentUser.is_moderator? ? moderation_reports.recent : []
  end
end

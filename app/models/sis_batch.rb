#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class SisBatch < ActiveRecord::Base
  include Workflow
  belongs_to :account
  has_many :sis_batch_log_entries, :order => :created_at
  serialize :data
  serialize :processing_errors, Array
  serialize :processing_warnings, Array
  belongs_to :attachment
  belongs_to :batch_mode_term, :class_name => 'EnrollmentTerm'

  attr_accessor :zip_path
  attr_accessible :batch_mode, :batch_mode_term
  
  def self.max_attempts
    5
  end
  
  def self.valid_import_types
    @valid_import_types ||= {
        "instructure_csv" => {
            :name => "Instructure formatted CSV or zipfile of CSVs",
            :callback => lambda {|batch| batch.process_instructure_csv_zip},
            :default => true
          }
      }
  end

  def self.create_with_attachment(account, import_type, attachment)
    batch = SisBatch.new
    batch.account = account
    batch.progress = 0
    batch.workflow_state = :created
    batch.data = {:import_type => import_type}
    batch.save

    Attachment.skip_scribd_submits(true)
    att = Attachment.new
    att.context = batch
    att.uploaded_data = attachment
    att.display_name = "sis_upload_#{batch.id}.zip"
    att.save
    Attachment.skip_scribd_submits(false)
    batch.attachment = att
    batch.save

    batch
  end

  workflow do
    state :created
    state :importing
    state :imported
    state :imported_with_messages
    state :failed
    state :failed_with_messages
  end

  def process
    if self.workflow_state == 'created'
      self.workflow_state = :importing
      self.progress = 0
      self.save

      import_scheme = SisBatch.valid_import_types[self.data[:import_type]]
      if import_scheme.nil?
        self.data[:error_message] = "Unrecognized import type"
        self.workflow_state = :failed
        self.save
      else
        import_scheme[:callback].call(self)
      end
    end
  rescue => e
    self.data[:error_message] = e.to_s
    self.data[:stack_trace] = "#{e.to_s}\n#{e.backtrace.join("\n")}"
    self.workflow_state = "failed"
    self.save
  end
  handle_asynchronously :process, :strand => proc { |sis_batch| "sis_batch:account:#{sis_batch.account_id}" }, :priority => Delayed::LOW_PRIORITY

  named_scope :needs_processing, lambda{
    {:conditions => ["sis_batches.workflow_state = 'needs_processing'"], :order => :created_at}
  }

  def fast_update_progress(val)
    self.progress = val
    SisBatch.update_all({:progress=>val}, "id=#{self.id}")
  end
  
  def importing?
    self.workflow_state == 'importing' || self.workflow_state == 'created'
  end

  def process_instructure_csv_zip
    require 'sis'
    download_zip
    importer = SIS::SisCsv.process(self.account, :files => [ @data_file.path ], :batch => self)
    finish importer.finished
  end

  def download_zip
    if self.data[:file_path]
      @data_file = File.open(self.data[:file_path], 'rb')
    else
      @data_file = self.attachment.open(:need_local_file => true)
    end
    @data_file
  end

  def finish(import_finished)
    @data_file.close if @data_file
    @data_file = nil
    if import_finished
      remove_previous_imports if self.batch_mode?
      self.workflow_state = :imported
      self.progress = 100
      self.workflow_state = :imported_with_messages if messages?
    else
      self.workflow_state = :failed
      self.workflow_state = :failed_with_messages if messages?
    end
    self.ended_at = Time.now
    self.save
  end

  def remove_previous_imports
    # delete courses that weren't in this batch, and only in the selected term if applicable
    scope = self.account.courses.active
    scope = scope.for_term(self.batch_mode_term) if self.batch_mode_term
    scope.scoped(:conditions => ["sis_batch_id is not null and sis_batch_id <> ?", self.id.to_s]).find_each do |course|
      course.destroy
    end

    # delete sections who weren't in this batch, and only whose course
    # was in the selected term if applicable
    scope = CourseSection.scoped(:conditions => ["course_sections.workflow_state = ? and course_sections.root_account_id = ? and course_sections.sis_batch_id is not null and course_sections.sis_batch_id <> ?", 'active', self.account.id, self.id.to_s])
    scope = scope.scoped(:include => :course, :select => "course_sections.*", :conditions => ["courses.enrollment_term_id = ?", self.batch_mode_term.id]) if self.batch_mode_term
    scope.find_each do |section|
      section.destroy
    end

    # delete enrollments for courses that weren't in this batch, in the
    # selected term if applicable
    scope = Enrollment.active.scoped(:include => :course, :select => "enrollments.*", :conditions => ["courses.account_id = ? and enrollments.sis_batch_id is not null and enrollments.sis_batch_id <> ?", self.account.id, self.id.to_s])
    scope = scope.scoped(:conditions => ["courses.enrollment_term_id = ?", self.batch_mode_term.id]) if self.batch_mode_term
    scope.find_each do |enrollment|
      enrollment.destroy
    end
  end

  def api_json
    data = {
      "created_at" => self.created_at,
      "ended_at" => self.ended_at,
      "updated_at" => self.updated_at,
      "progress" => self.progress,
      "id" => self.id,
      "workflow_state" => self.workflow_state,
      "data" => self.data
    }
    data["processing_errors"] = self.processing_errors if self.processing_errors.present?
    data["processing_warnings"] = self.processing_warnings if self.processing_warnings.present?
    data["sis_batch_log_entries"] = self.sis_batch_log_entries if self.sis_batch_log_entries.present?
    return data.to_json
  end

  private
  
  def messages?
    (self.processing_errors && self.processing_errors.length > 0) || (self.processing_warnings && self.processing_warnings.length > 0)
  end
  
end

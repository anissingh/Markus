class AutomatedTestsController < ApplicationController
  include AutomatedTestsHelper

  before_action { authorize! }

  content_security_policy only: :manage do |p|
    # required because @rjsf/core uses ajv which calls
    # eval (javascript) and creates an image as a blob.
    # TODO: remove this when possible
    p.script_src :self, "'strict-dynamic'", "'unsafe-eval'"
  end

  def update
    assignment = Assignment.find(params[:assignment_id])
    test_specs = params[:schema_form_data].permit!.to_h
    begin
      assignment.update! assignment_params
    rescue StandardError => e
      flash_message(:error, e.message)
      raise ActiveRecord::Rollback
    end
    @current_job = AutotestSpecsJob.perform_later(request.protocol + request.host_with_port, assignment, test_specs)
    session[:job_id] = @current_job.job_id
    # TODO: the page is not correctly drawn when using render
    redirect_to action: 'manage', assignment_id: params[:assignment_id]
  end

  # Manage is called when the Automated Test UI is loaded
  def manage
    @assignment = Assignment.find(params[:assignment_id])
    flash_message(:warning, I18n.t('automated_tests.tests_run')) if @assignment.groupings.joins(:test_runs).exists?
    render layout: 'assignment_content'
  end

  def student_interface
    @assignment = Assignment.find(params[:assignment_id])
    @student = current_role
    @grouping = @student.accepted_grouping_for(@assignment.id)

    unless @grouping.nil?
      @grouping.refresh_test_tokens
      @authorized = flash_allowance(:notice,
                                    allowance_to(:run_tests?,
                                                 current_role,
                                                 context: { assignment: @assignment, grouping: @grouping })).value
    end

    render layout: 'assignment_content'
  end

  def execute_test_run
    assignment = Assignment.find(params[:assignment_id])
    grouping = current_role.accepted_grouping_for(assignment.id)
    grouping.refresh_test_tokens
    allowed = flash_allowance(:error, allowance_to(:run_tests?,
                                                   current_role,
                                                   context: { assignment: assignment, grouping: grouping })).value
    if allowed
      grouping.decrease_test_tokens
      @current_job = AutotestRunJob.perform_later(request.protocol + request.host_with_port,
                                                  current_role.id,
                                                  assignment.id,
                                                  [grouping.group_id],
                                                  collected: false)
      session[:job_id] = @current_job.job_id
      flash_message(:success, I18n.t('automated_tests.test_run_table.tests_running'))
    end
  rescue StandardError => e
    flash_message(:error, e.message)
  end

  def get_test_runs_students
    grouping = current_role.accepted_grouping_for(params[:assignment_id])
    render json: grouping.test_runs_students
  end

  def populate_autotest_manager
    assignment = Assignment.find(params[:assignment_id])
    files_dir = Pathname.new assignment.autotest_files_dir
    file_keys = []
    files_data = assignment.autotest_files.map do |file|
      if files_dir.join(file).directory?
        { key: "#{file}/" }
      else
        file_keys << file
        time = ''
        if files_dir.join(file).exist?
          time = I18n.l(File.mtime(files_dir.join(file)).in_time_zone(current_user.time_zone))
        end
        { key: file, size: 1, submitted_date: time,
          url: download_file_course_assignment_automated_tests_url(assignment.course, assignment, file_name: file) }
      end
    end
    file_keys.sort!

    schema_data = JSON.parse(assignment.course.autotest_setting.schema)
    fill_in_schema_data!(schema_data, file_keys, assignment)

    test_specs = autotest_settings_for(assignment)
    assignment_data = assignment.assignment_properties.attributes.slice(*required_params.map(&:to_s))
    assignment_data['token_start_date'] ||= Time.current
    assignment_data['token_start_date'] = assignment_data['token_start_date'].iso8601
    data = { schema: schema_data, files: files_data, formData: test_specs }.merge(assignment_data)
    render json: data
  end

  def download_file
    assignment = Assignment.find(params[:assignment_id])
    file_path = File.join(assignment.autotest_files_dir, params[:file_name])
    filename = File.basename params[:file_name]
    if File.exist?(file_path)
      send_file_download file_path, filename: filename
    else
      render plain: t('student.submission.missing_file', file_name: filename)
    end
  end

  ##
  # Download all files from the assignment.autotest_files_dir directory as a zip file
  ##
  def download_files
    assignment = Assignment.find(params[:assignment_id])
    zip_path = assignment.zip_automated_test_files(current_role)
    send_file zip_path, filename: File.basename(zip_path)
  end

  def upload_files
    assignment = Assignment.find(params[:assignment_id])
    new_folders = params[:new_folders] || []
    delete_folders = params[:delete_folders] || []
    delete_files = params[:delete_files] || []
    new_files = params[:new_files] || []
    unzip = params[:unzip] == 'true'

    upload_files_helper(new_folders, new_files, unzip: unzip) do |f|
      if f.is_a?(String) # is a directory
        folder_path = File.join(assignment.autotest_files_dir, params[:path], f)
        FileUtils.mkdir_p(folder_path)
      else
        if f.size > assignment.course.max_file_size
          flash_now(:error, t('student.submission.file_too_large',
                              file_name: f.original_filename,
                              max_size: (assignment.course.max_file_size / 1_000_000.00).round(2)))
          next
        elsif f.size == 0
          flash_now(:warning, t('student.submission.empty_file_warning', file_name: f.original_filename))
        end
        file_path = File.join(assignment.autotest_files_dir, params[:path], f.original_filename)
        FileUtils.mkdir_p(File.dirname(file_path))
        file_content = f.read
        File.write(file_path, file_content, mode: 'wb')
      end
    end
    delete_folders.each do |f|
      folder_path = File.join(assignment.autotest_files_dir, f)
      FileUtils.rm_rf(folder_path)
    end
    delete_files.each do |f|
      file_path = File.join(assignment.autotest_files_dir, f)
      File.delete(file_path)
    end
    render partial: 'update_files'
  end

  def download_specs
    assignment = Assignment.find(params[:assignment_id])
    specs = autotest_settings_for(assignment)
    specs['testers']&.each do |tester_info|
      tester_info['test_data']&.each do |test_info|
        test_info['extra_info']&.delete('test_group_id')
      end
    end
    send_data specs.to_json, filename: TestRun::SPECS_FILE
  end

  def upload_specs
    assignment = Assignment.find(params[:assignment_id])
    if params[:specs_file].respond_to? :read
      file_content = params[:specs_file].read
      begin
        test_specs = JSON.parse file_content
      rescue JSON::ParserError
        flash_now(:error, I18n.t('automated_tests.invalid_specs_file'))
        head :unprocessable_entity
      rescue StandardError => e
        flash_now(:error, e.message)
        head :unprocessable_entity
      else
        @current_job = AutotestSpecsJob.perform_later(request.protocol + request.host_with_port, assignment, test_specs)
        session[:job_id] = @current_job.job_id
        render 'shared/_poll_job'
      end
    else
      head :unprocessable_entity
    end
  end

  protected

  def implicit_authorization_target
    OpenStruct.new policy_class: AutomatedTestPolicy
  end

  private

  def required_params
    [:enable_test, :enable_student_tests, :tokens_per_period, :token_period, :token_start_date,
     :non_regenerating_tokens, :unlimited_tokens]
  end

  def assignment_params
    params.require(:assignment).permit(*required_params)
  end
end

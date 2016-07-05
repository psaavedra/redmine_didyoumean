class SearchIssuesController < ApplicationController
  unloadable

  def index
  
    @query = params[:query] || ""   
    @query.strip!

    logger.debug "Got request for [#{@query}]"
    logger.debug "Did you mean settings: #{Setting.plugin_redmine_didyoumean.to_json}"

    all_words = true # if true, returns records that contain all the words specified in the input query

    # extract tokens from the query
    # eg. hello "bye bye" => ["hello", "bye bye"]
    @tokens = @query.scan(%r{((\s|^)"[\s\w]+"(\s|$)|\S+)}).collect {|m| m.first.gsub(%r{(^\s*"\s*|\s*"\s*$)}, '')}
    
    min_length = Setting.plugin_redmine_didyoumean['min_word_length'].to_i
    @tokens = @tokens.uniq.select {|w| w.length >= min_length }

    if !@tokens.empty?
      # no more than 5 tokens to search for
      # this is probably too strict, in this use case
      @tokens.slice! 5..-1 if @tokens.size > 5

      url_more_conditions = (['%s'] * ( @tokens.length)).join('+')
      @url_more = "/search?utf8=✓&issues=1&q=" + (url_more_conditions % @tokens)
      
      if all_words
        separator = ' AND '
      else
        separator = ' OR '
      end

      @tokens.map! {|cur| '%' + cur +'%'}

      conditions = (['lower(subject) like lower(?)'] * @tokens.length).join(separator)
      variables = @tokens

      # pick the current project
      project = Project.find(params[:project_id]) unless params[:project_id].blank?

      # when editing an existing issue this will hold its id
      issue_id = params[:issue_id] unless params[:issue_id].blank?
      
      case Setting.plugin_redmine_didyoumean['project_filter']
      when '2'
        project_tree = Project.all
      when '1'
        # search subprojects too
        project_tree = project ? (project.self_and_descendants.active) : nil
      when '0'
        project_tree = [project]
      else
        logger.warn "Unrecognized option for project filter: [#{Setting.plugin_redmine_didyoumean['project_filter']}], skipping"
      end

      if project_tree
        # check permissions
        scope = project_tree.select {|p| User.current.allowed_to?(:view_issues, p)}
        logger.debug "Set project filter to #{scope}"
        conditions += " AND project_id in (?)"
        variables << scope
      end

      if !issue_id.nil?
        logger.debug "Excluding issue #{issue_id}"
        conditions += " AND issues.id != (?)"
        variables << issue_id
      end
     
      if Rails::VERSION::MAJOR > 3
          valid_statuses = IssueStatus.where(["is_closed = ?", true]).collect{|s| s.id.to_s }
      else
          valid_statuses = IssueStatus.all(:conditions => ["is_closed = ?", true])
      end
      conditions_closed = conditions + " AND status_id in (?)"
      variables_closed = variables + [valid_statuses]
      
      if Rails::VERSION::MAJOR > 3
          valid_statuses = IssueStatus.where(["is_closed <> ?", true]).collect{|s| s.id.to_s }
      else
          valid_statuses = IssueStatus.all(:conditions => ["is_closed <> ?", true])
      end
      conditions_open = conditions + " AND status_id in (?)"
      variables_open = variables + [valid_statuses]

      limit = Setting.plugin_redmine_didyoumean['limit']
      limit = 5 if limit.nil? or limit.empty?

      @issues_closed = []
      if Rails::VERSION::MAJOR > 3
          logger.error "Set project filter to #{conditions_open}"
          logger.error "Set project filter to #{variables_open}"

        @issues_open = Issue.visible.where([conditions_open, *variables_open]).limit(limit)
        if Setting.plugin_redmine_didyoumean['show_only_open'] != "1"
          @issues_closed = Issue.visible.where([conditions_closed, *variables_closed]).limit(limit)
        end
      else
        @issues_open = Issue.visible.find(:all, :conditions => [conditions_open, *variables_open], :limit => limit)
        if Setting.plugin_redmine_didyoumean['show_only_open'] != "1"
          @issues_closed = Issue.visible.find(:all, :conditions => [conditions_closed, *variables_closed], :limit => limit)
        end
      end
      @count_open = Issue.visible.where([conditions_open, *variables_open]).count()
      @count_closed = Issue.visible.where([conditions_closed, *variables_closed]).count()

      if Rails::VERSION::MAJOR > 3
        @issues_open = Issue.visible.where([conditions_open, *variables_open]).limit(limit)
        @issues_closed = Issue.visible.where([conditions_closed, *variables_closed]).limit(limit)
      else
        @issues_open = Issue.visible.find(:all, :conditions => [conditions_open, *variables_open], :limit => limit)
        @issues_closed = Issue.visible.find(:all, :conditions => [conditions_closed, *variables_closed], :limit => limit)
      end
      @count_open = Issue.visible.where([conditions_open, *variables_open]).count()
      @count_closed = Issue.visible.where([conditions_closed, *variables_closed]).count()
      @count = @count_open + @count_closed

      # order by decreasing creation time. Some relevance sort would be a lot more appropriate here
      @issues_open = @issues_open.sort {|a,b| b.id <=> a.id}
      @issues_closed = @issues_closed.sort {|a,b| b.id <=> a.id}
      @issues = @issues_open + @issues_closed

      logger.debug "#{@count} results found, returning the first #{@issues.length}"
    else
      @query = ""
      @count = 0
      @issues = []
      @url_more = ""
    end

    render :json => { :url_more => @url_more, :total => @count, :issues => @issues.map{|i| 
      { #make a deep copy, otherwise rails3 makes weird stuff nesting the issue as mapping.
      :id => i.id,
      :tracker_name => i.tracker.name,
      :subject => i.subject,
      :status_name => i.status.name,
      :project_name => i.project.name
      }
    }}
  end
end

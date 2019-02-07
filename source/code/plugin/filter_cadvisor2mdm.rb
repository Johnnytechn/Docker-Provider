# Copyright (c) Microsoft Corporation.  All rights reserved.

# frozen_string_literal: true

module Fluent
    require 'logger'
    require 'json'
    require_relative 'oms_common'

	class CAdvisor2MdmFilter < Filter
		Fluent::Plugin.register_filter('filter_cadvisor2mdm', self)
		
		config_param :enable_log, :integer, :default => 0
        config_param :log_path, :string, :default => '/var/opt/microsoft/docker-cimprov/log/filter_cadvisor2mdm.log'
        config_param :custom_metrics_azure_regions, :string
        config_param :metrics_to_collect, :string, :default => 'cpuUsageNanoCores,memoryWorkingSetBytes,memoryRssBytes'
        
        @@cpu_usage_milli_cores = 'cpuUsageMilliCores'
        @@cpu_usage_nano_cores = 'cpuusagenanocores'
        @@object_name_k8s_node = 'K8SNode'
        @@hostName = (OMS::Common.get_hostname)
        @@custom_metrics_template = '
            { 
                "time": "%{timestamp}", 
                "data": { 
                    "baseData": { 
                        "metric": "%{metricName}", 
                        "namespace": "Insights.Container/nodes", 
                        "dimNames": [ 
                        "host"
                        ], 
                        "series": [ 
                        { 
                            "dimValues": [ 
                            "%{hostvalue}"
                            ], 
                            "min": %{metricminvalue},
                            "max": %{metricmaxvalue}, 
                            "sum": %{metricsumvalue}, 
                            "count": 1 
                        } 
                        ] 
                    } 
                } 
            }'

        @process_incoming_stream = true
        @metrics_to_collect_hash = {}

		def initialize
            super
		end

		def configure(conf)
			super
			@log = nil
			
			if @enable_log
				@log = Logger.new(@log_path, 'weekly')
				@log.debug {'Starting filter_cadvisor2mdm plugin'}
			end
		end

        def start
            super
            @process_incoming_stream = check_custom_metrics_availability
            @metrics_to_collect_hash = build_metrics_hash
            @log.debug "After check_custom_metrics_availability process_incoming_stream #{@process_incoming_stream}"
            
            # initialize cpu and memory limit 
            if @process_incoming_stream
                @cpu_capacity = 0.0
                @memory_capacity = 0.0
                ensure_cpu_memory_capacity_set
            end
        end

        def build_metrics_hash
            @log.debug "Building Hash of Metrics to Collect"
            metrics_to_collect_arr = @metrics_to_collect.split(',').map(&:strip)
            metrics_hash = metrics_to_collect_arr.map {|x| [x.downcase,true]}.to_h
            @log.info "Metrics Collected : #{metrics_hash}"
            return metrics_hash
        end

        def check_custom_metrics_availability
            aks_region = ENV['AKS_REGION']
            aks_resource_id = ENV['AKS_RESOURCE_ID']
            if aks_region.to_s.empty? && aks_resource_id.to_s.empty?
                false # This will also take care of AKS-Engine Scenario. AKS_REGION/AKS_RESOURCE_ID is not set for AKS-Engine. Only ACS_RESOURCE_NAME is set
            end
            @log.debug "AKS_REGION #{aks_region}"
            custom_metrics_regions_arr = @custom_metrics_azure_regions.split(',')
            custom_metrics_regions_hash = custom_metrics_regions_arr.map {|x| [x.downcase,true]}.to_h

            @log.debug "Custom Metrics Regions Hash #{custom_metrics_regions_hash}"

            if custom_metrics_regions_hash.key?(aks_region.downcase)
                @log.debug "Returning true for check_custom_metrics_availability"
                true
            else 
                @log.debug "Returning false for check_custom_metrics_availability"
                false
            end
        end

		def shutdown
			super
		end

        def filter(tag, time, record)
            begin
                if @process_incoming_stream
                    object_name = record['DataItems'][0]['ObjectName']
                    counter_name = record['DataItems'][0]['Collections'][0]['CounterName']
                    if object_name == @@object_name_k8s_node && @metrics_to_collect_hash.key?(counter_name.downcase)
                        percentage_metric_value = 0.0

                        # Compute and send % CPU and Memory
                        metric_value = record['DataItems'][0]['Collections'][0]['Value']
                        if counter_name.downcase == @@cpu_usage_nano_cores
                            metric_name = @@cpu_usage_milli_cores
                            metric_value = metric_value/1000000
                            if @cpu_capacity != 0.0
                                percentage_metric_value = (metric_value*1000000)*100/@cpu_capacity
                            end
                        end

                        if counter_name.start_with?("memory")
                            metric_name = counter_name
                            if @memory_capacity != 0.0
                                percentage_metric_value = metric_value*100/@memory_capacity
                            end
                        end 
                        return get_metric_records(record, metric_name, metric_value, percentage_metric_value)
                    else 
                        return []
                    end
                else
                    return []
                end
            rescue Exception => e
                @log.info "Error processing cadvisor record Exception: #{e.class} Message: #{e.message}"
                ApplicationInsightsUtility.sendExceptionTelemetry(e.backtrace)
                return []
            end
        end

        def ensure_cpu_memory_capacity_set

            @log.info "ensure_cpu_memory_capacity_set @cpu_capacity #{@cpu_capacity} @memory_capacity #{@memory_capacity}"
            if @cpu_capacity != 0.0 && @memory_capacity != 0.0
                @log.info "CPU And Memory Capacity are already set"
                return
            end

            begin 
                nodeInventory = JSON.parse(KubernetesApiClient.getKubeResourceInfo("nodes?fieldSelector=metadata.name%3D#{@@hostName}").body)
            rescue Exception => e
                @log.info "Error when getting nodeInventory from kube API. Exception: #{e.class} Message: #{e.message} "
                ApplicationInsightsUtility.sendExceptionTelemetry(e.backtrace)
            end
            if !nodeInventory.nil? 
                cpu_capacity_json = KubernetesApiClient.parseNodeLimits(nodeInventory, "capacity", "cpu", "cpuCapacityNanoCores")
                if !cpu_capacity_json.nil? && !cpu_capacity_json[0]['DataItems'][0]['Collections'][0]['Value'].to_s.nil?
                    @cpu_capacity = cpu_capacity_json[0]['DataItems'][0]['Collections'][0]['Value']
                    @log.info "CPU Limit #{@cpu_capacity}"
                else
                    @log.info "Error getting cpu_capacity"
                end
                memory_capacity_json = KubernetesApiClient.parseNodeLimits(nodeInventory, "capacity", "memory", "memoryCapacityBytes")
                if !memory_capacity_json.nil? && !memory_capacity_json[0]['DataItems'][0]['Collections'][0]['Value'].to_s.nil?
                    @memory_capacity = memory_capacity_json[0]['DataItems'][0]['Collections'][0]['Value']
                    @log.info "Memory Limit #{@memory_capacity}"
                else
                    @log.info "Error getting memory_capacity"
                end
            end
        end
        
        def get_metric_records(record, metric_name, metric_value, percentage_metric_value)
            records = []
            custommetricrecord = @@custom_metrics_template % {
                timestamp: record['DataItems'][0]['Timestamp'],
                metricName: metric_name,
                hostvalue: record['DataItems'][0]['Host'],
                objectnamevalue: record['DataItems'][0]['ObjectName'],
                instancenamevalue: record['DataItems'][0]['InstanceName'],
                metricminvalue: metric_value,
                metricmaxvalue: metric_value,
                metricsumvalue: metric_value
                }
            records.push(JSON.parse(custommetricrecord))

            if !percentage_metric_value.nil?
                additional_record = @@custom_metrics_template % {
                    timestamp: record['DataItems'][0]['Timestamp'],
                    metricName: metric_name + "Percentage",
                    hostvalue: record['DataItems'][0]['Host'],
                    objectnamevalue: record['DataItems'][0]['ObjectName'],
                    instancenamevalue: record['DataItems'][0]['InstanceName'],
                    metricminvalue: percentage_metric_value,
                    metricmaxvalue: percentage_metric_value,
                    metricsumvalue: percentage_metric_value
                    }
                    records.push(JSON.parse(additional_record))
            end
            @log.info "Metric Name: #{metric_name} Metric Value: #{metric_value} Percentage Metric Value: #{percentage_metric_value}"
            return records
        end

        
        def filter_stream(tag, es)
            new_es = MultiEventStream.new
            ensure_cpu_memory_capacity_set
            es.each { |time, record|
              begin
                filtered_records = filter(tag, time, record)
                filtered_records.each {|filtered_record| 
                    new_es.add(time, filtered_record) if filtered_record
                } if filtered_records
              rescue => e
                router.emit_error_event(tag, time, record, e)
              end
            }
            new_es
          end
	end
end

{{/*
Expand the name of the chart.
*/}}
{{- define "apexdata-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "apexdata-agent.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "apexdata-agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "apexdata-agent.labels" -}}
helm.sh/chart: {{ include "apexdata-agent.chart" . }}
{{ include "apexdata-agent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: apexdata
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "apexdata-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "apexdata-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Agent specific labels
*/}}
{{- define "apexdata-agent.agent.labels" -}}
{{ include "apexdata-agent.labels" . }}
app.kubernetes.io/component: agent
{{- end }}

{{/*
Agent selector labels
*/}}
{{- define "apexdata-agent.agent.selectorLabels" -}}
{{ include "apexdata-agent.selectorLabels" . }}
app.kubernetes.io/component: agent
{{- end }}

{{/*
Shard specific labels
*/}}
{{- define "apexdata-agent.shard.labels" -}}
{{ include "apexdata-agent.labels" . }}
app.kubernetes.io/component: shard
{{- end }}

{{/*
Shard selector labels
*/}}
{{- define "apexdata-agent.shard.selectorLabels" -}}
{{ include "apexdata-agent.selectorLabels" . }}
app.kubernetes.io/component: shard
{{- end }}

{{/*
Unscheduled pods specific labels
*/}}
{{- define "apexdata-agent.unscheduledPods.labels" -}}
{{ include "apexdata-agent.labels" . }}
app.kubernetes.io/component: unscheduled-pods
{{- end }}

{{/*
Unscheduled pods selector labels
*/}}
{{- define "apexdata-agent.unscheduledPods.selectorLabels" -}}
{{ include "apexdata-agent.selectorLabels" . }}
app.kubernetes.io/component: unscheduled-pods
{{- end }}

{{/*
OTel Collector specific labels
*/}}
{{- define "apexdata-agent.otelCollector.labels" -}}
{{ include "apexdata-agent.labels" . }}
app.kubernetes.io/component: otel-collector
{{- end }}

{{/*
OTel Collector selector labels
*/}}
{{- define "apexdata-agent.otelCollector.selectorLabels" -}}
{{ include "apexdata-agent.selectorLabels" . }}
app.kubernetes.io/component: otel-collector
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "apexdata-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "apexdata-agent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Namespace
*/}}
{{- define "apexdata-agent.namespace" -}}
{{- default .Release.Namespace .Values.global.namespace }}
{{- end }}

{{/*
OTel direct endpoint URL
*/}}
{{- define "apexdata-agent.otelEndpoint" -}}
https://{{ .Values.apexdata.clientName }}.{{ .Values.apexdata.endpointDomain }}:{{ .Values.apexdata.endpointPort }}
{{- end }}

{{/*
OTel Basic Auth header
*/}}
{{- define "apexdata-agent.otelAuthHeader" -}}
Basic {{ printf "%s:%s" .Values.apexdata.clientName .Values.apexdata.password | b64enc }}
{{- end }}

{{/*
Image pull secrets
*/}}
{{- define "apexdata-agent.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Resolve agent image: component override > global default
Usage: {{ include "apexdata-agent.agentImage" (dict "component" .Values.agent "global" .Values.image) }}
*/}}
{{- define "apexdata-agent.agentImage" -}}
{{- $repo := default .global.repository ((.component).image).repository -}}
{{- $tag := default .global.tag ((.component).image).tag -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end }}

{{/*
Resolve agent image pull policy: component override > global default
Usage: {{ include "apexdata-agent.agentPullPolicy" (dict "component" .Values.agent "global" .Values.image) }}
*/}}
{{- define "apexdata-agent.agentPullPolicy" -}}
{{- default .global.pullPolicy ((.component).image).pullPolicy -}}
{{- end }}

// Entry for the vendored xyflow bundle. scripts/xyflow_vendor.rb bundles this
// file into one classic IIFE that exposes what a diagram screen needs on
// window.CfXyflow, with the React Flow stylesheet inlined as a string so the
// screen never fetches anything.
import * as React from 'react';
import * as ReactDOM from 'react-dom';
import { flushSync } from 'react-dom';
import { createRoot } from 'react-dom/client';
import {
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
  useNodesInitialized,
  Background,
  MarkerType,
  Position,
  Handle,
  EdgeLabelRenderer,
  BaseEdge,
  getBezierPath,
  getSmoothStepPath
} from '@xyflow/react';
import dagre from '@dagrejs/dagre';
import css from '@xyflow/react/dist/style.css';

window.CfXyflow = {
  React,
  ReactDOM,
  createRoot,
  flushSync,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
  useNodesInitialized,
  Background,
  MarkerType,
  Position,
  Handle,
  EdgeLabelRenderer,
  BaseEdge,
  getBezierPath,
  getSmoothStepPath,
  dagre,
  css
};

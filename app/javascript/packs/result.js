// JavaScript files for the main result page (edit.html and view_marks.html).

import { render } from 'react-dom';
import 'javascripts/react_config';
import { makeAnnotationTable } from 'javascripts/Components/annotation_table';
import { makeAnnotationManager } from 'javascripts/Components/Result/annotation_manager';

window.makeAnnotationTable = makeAnnotationTable;
window.makeAnnotationManager = makeAnnotationManager;
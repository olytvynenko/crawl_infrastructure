#!/usr/bin/env python3
"""
Generate ODT documentation from markdown file
"""
import sys
import re

try:
    from odf.opendocument import OpenDocumentText
    from odf.style import Style, TextProperties, ParagraphProperties
    from odf.text import H, P, List, ListItem
    from odf import teletype
except ImportError:
    print("Installing required package: odfpy")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "odfpy"])
    from odf.opendocument import OpenDocumentText
    from odf.style import Style, TextProperties, ParagraphProperties
    from odf.text import H, P, List, ListItem
    from odf import teletype

def create_styles(doc):
    """Create styles for the document"""
    # Heading 1 style
    h1style = Style(name="Heading 1", family="paragraph")
    h1style.addElement(TextProperties(fontsize="20pt", fontweight="bold"))
    h1style.addElement(ParagraphProperties(margintop="12pt", marginbottom="6pt"))
    doc.styles.addElement(h1style)
    
    # Heading 2 style
    h2style = Style(name="Heading 2", family="paragraph")
    h2style.addElement(TextProperties(fontsize="16pt", fontweight="bold"))
    h2style.addElement(ParagraphProperties(margintop="10pt", marginbottom="5pt"))
    doc.styles.addElement(h2style)
    
    # Heading 3 style
    h3style = Style(name="Heading 3", family="paragraph")
    h3style.addElement(TextProperties(fontsize="14pt", fontweight="bold"))
    h3style.addElement(ParagraphProperties(margintop="8pt", marginbottom="4pt"))
    doc.styles.addElement(h3style)
    
    # Code style
    codestyle = Style(name="Code", family="text")
    codestyle.addElement(TextProperties(fontfamily="monospace", fontsize="10pt"))
    doc.styles.addElement(codestyle)
    
    return doc

def convert_markdown_to_odt(md_file, odt_file):
    """Convert markdown file to ODT format"""
    # Create document
    doc = OpenDocumentText()
    doc = create_styles(doc)
    
    # Read markdown content
    with open(md_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Split into lines for processing
    lines = content.split('\n')
    
    # Process lines
    i = 0
    in_code_block = False
    in_list = False
    current_list = None
    
    while i < len(lines):
        line = lines[i]
        
        # Code blocks
        if line.strip().startswith('```'):
            in_code_block = not in_code_block
            i += 1
            continue
            
        if in_code_block:
            p = P(text=line)
            doc.text.addElement(p)
            i += 1
            continue
        
        # Headers
        if line.startswith('# '):
            h = H(outlinelevel=1, text=line[2:])
            doc.text.addElement(h)
        elif line.startswith('## '):
            h = H(outlinelevel=2, text=line[3:])
            doc.text.addElement(h)
        elif line.startswith('### '):
            h = H(outlinelevel=3, text=line[4:])
            doc.text.addElement(h)
        elif line.startswith('#### '):
            h = H(outlinelevel=4, text=line[5:])
            doc.text.addElement(h)
        
        # Lists
        elif line.strip().startswith('- ') or line.strip().startswith('* '):
            if not in_list:
                current_list = List()
                in_list = True
            
            # Extract list item text
            item_text = line.strip()[2:]
            list_item = ListItem()
            p = P(text=item_text)
            list_item.addElement(p)
            current_list.addElement(list_item)
            
            # Check if next line is also a list item
            if i + 1 >= len(lines) or not (lines[i + 1].strip().startswith('- ') or lines[i + 1].strip().startswith('* ')):
                doc.text.addElement(current_list)
                in_list = False
                current_list = None
        
        # Tables (simplified - just show as text)
        elif line.strip().startswith('|'):
            p = P(text=line)
            doc.text.addElement(p)
        
        # Regular paragraphs
        elif line.strip():
            # Handle bold text
            line = re.sub(r'\*\*(.+?)\*\*', r'\\1', line)
            # Handle code inline
            line = re.sub(r'`(.+?)`', r'\\1', line)
            
            p = P(text=line)
            doc.text.addElement(p)
        
        # Empty lines
        else:
            p = P(text="")
            doc.text.addElement(p)
        
        i += 1
    
    # Save document
    doc.save(odt_file)
    print(f"ODT file created: {odt_file}")

if __name__ == "__main__":
    md_file = "COMPREHENSIVE_DOCUMENTATION.md"
    odt_file = "CRAWL_INFRASTRUCTURE_DOCUMENTATION.odt"
    
    convert_markdown_to_odt(md_file, odt_file)